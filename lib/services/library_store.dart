// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import '../core/files.dart';
import '../core/library.dart';
import 'catalog.dart';

enum LibrarySourceKind { directory, file }

class LibrarySource {
  final String id;
  final String path;
  final LibrarySourceKind kind;
  final bool scanEnabled;
  final bool published;
  final bool available;
  final int? lastSuccessfulScan;
  const LibrarySource({
    required this.id,
    required this.path,
    required this.kind,
    required this.scanEnabled,
    required this.published,
    required this.available,
    this.lastSuccessfulScan,
  });
}

class IndexedPackage {
  final Package package;
  final bool available;
  final bool published;
  const IndexedPackage(
    this.package, {
    required this.available,
    required this.published,
  });
}

class SourceScan {
  final LibrarySource source;
  final ScanResult result;
  final bool complete;
  const SourceScan(this.source, this.result, {required this.complete});
}

/// The only writer for the durable library inventory. SQLite stays local to the
/// process that owns the scan roots; clients consume the HTTP representation.
class LibraryStore {
  final Database _db;
  final String path;
  LibraryStore._(this.path, this._db);

  static Future<LibraryStore> open(Directory directory) async {
    await directory.create(recursive: true);
    final path = p.join(directory.path, 'library.sqlite');
    final store = LibraryStore._(path, sqlite3.open(path));
    store._migrate();
    return store;
  }

  void _migrate() {
    _db.execute('PRAGMA foreign_keys = ON');
    _db.execute('PRAGMA journal_mode = WAL');
    _db.execute('PRAGMA busy_timeout = 5000');
    final version =
        _db.select('PRAGMA user_version').single['user_version'] as int;
    if (version > 2) {
      throw StateError('Library database is newer than this application');
    }
    if (version == 0) {
      _db.execute('''
        CREATE TABLE sources (
          id TEXT PRIMARY KEY,
          path TEXT NOT NULL UNIQUE,
          kind TEXT NOT NULL CHECK(kind IN ('directory','file')),
          scan_enabled INTEGER NOT NULL DEFAULT 1 CHECK(scan_enabled IN (0,1)),
          published INTEGER NOT NULL DEFAULT 1 CHECK(published IN (0,1)),
          available INTEGER NOT NULL DEFAULT 1 CHECK(available IN (0,1)),
          last_successful_scan INTEGER,
          last_error TEXT
        );
        CREATE TABLE packages (
          id TEXT PRIMARY KEY,
          path TEXT NOT NULL UNIQUE,
          source_snapshot TEXT NOT NULL,
          override_snapshot TEXT NOT NULL,
          title_id TEXT,
          evidence TEXT NOT NULL,
          group_override TEXT,
          package_group_id TEXT,
          package_version INTEGER,
          kind_override TEXT,
          observed_at INTEGER NOT NULL
        );
        CREATE TABLE package_sources (
          package_id TEXT NOT NULL REFERENCES packages(id) ON DELETE CASCADE,
          source_id TEXT NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
          scan_generation INTEGER NOT NULL,
          PRIMARY KEY(package_id, source_id)
        );
        CREATE INDEX package_sources_source_generation
          ON package_sources(source_id, scan_generation);
        CREATE TABLE manual_overrides (
          path TEXT PRIMARY KEY,
          payload TEXT NOT NULL
        );
        CREATE TABLE library_state (
          singleton INTEGER PRIMARY KEY CHECK(singleton = 1),
          schema_name TEXT NOT NULL,
          server_id TEXT NOT NULL,
          revision INTEGER NOT NULL,
          generation INTEGER NOT NULL
        );
        INSERT INTO library_state(singleton, schema_name, server_id, revision, generation)
          VALUES(1, 'awoo-v1', '', 0, 0);
        PRAGMA user_version = 1;
      ''');
    }
    if (version < 2) {
      _db.execute('''
        CREATE TABLE IF NOT EXISTS title_metadata (
          title_id TEXT PRIMARY KEY,
          name TEXT NOT NULL,
          publisher TEXT NOT NULL,
          icon_url TEXT
        );
        PRAGMA user_version = 2;
      ''');
    }
    final row = _db
        .select('SELECT server_id FROM library_state WHERE singleton = 1')
        .single;
    if ((row['server_id'] as String).isEmpty) {
      _db.execute(
        'UPDATE library_state SET server_id = ? WHERE singleton = 1',
        [_serverId()],
      );
    }
  }

  String _serverId() {
    final random = Random.secure();
    final bytes = List<int>.generate(24, (_) => random.nextInt(256));
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  static String canonicalPath(String value) => p.normalize(p.absolute(value));
  static String sourceId(String value) =>
      sha256.convert(utf8.encode(canonicalPath(value))).toString();
  static String _json(Map? value) =>
      jsonEncode(value ?? const <String, dynamic>{});

  List<LibrarySource> sources({bool enabledOnly = false}) {
    final rows = _db.select(
      'SELECT * FROM sources ${enabledOnly ? 'WHERE scan_enabled = 1' : ''} ORDER BY path COLLATE NOCASE',
    );
    return [for (final row in rows) _source(row)];
  }

  LibrarySource _source(Row row) => LibrarySource(
    id: row['id'] as String,
    path: row['path'] as String,
    kind: LibrarySourceKind.values.byName(row['kind'] as String),
    scanEnabled: (row['scan_enabled'] as int) == 1,
    published: (row['published'] as int) == 1,
    available: (row['available'] as int) == 1,
    lastSuccessfulScan: row['last_successful_scan'] as int?,
  );

  Future<LibrarySource> addSource(String value, {bool published = true}) async {
    final path = canonicalPath(value);
    final type = await FileSystemEntity.type(path, followLinks: false);
    if (type != FileSystemEntityType.directory &&
        type != FileSystemEntityType.file) {
      throw ArgumentError(
        'Source must be an existing directory or package file',
      );
    }
    if (type == FileSystemEntityType.file && !LibraryScanner.supported(path)) {
      throw ArgumentError('Unsupported package file');
    }
    final kind = type == FileSystemEntityType.directory
        ? LibrarySourceKind.directory
        : LibrarySourceKind.file;
    return registerSource(path, kind: kind, published: published);
  }

  /// Configured headless sources may be temporarily absent while a NAS mount is
  /// down. Registering their expected kind preserves the prior inventory.
  LibrarySource registerSource(
    String value, {
    required LibrarySourceKind kind,
    bool published = true,
  }) {
    final path = canonicalPath(value);
    final id = sourceId(path);
    _db.execute(
      '''
      INSERT INTO sources(id,path,kind,published,available)
      VALUES(?,?,?,?,1)
      ON CONFLICT(path) DO UPDATE SET scan_enabled=1,published=excluded.published,kind=excluded.kind
    ''',
      [id, path, kind.name, published ? 1 : 0],
    );
    return sources().singleWhere((source) => source.path == path);
  }

  void removeSource(String id) => _transaction(() {
    _db.execute('DELETE FROM sources WHERE id = ?', [id]);
    _db.execute(
      'DELETE FROM packages WHERE id NOT IN (SELECT package_id FROM package_sources)',
    );
    _advanceRevision();
  });

  void updateSource(String id, {bool? scanEnabled, bool? published}) {
    if (scanEnabled == null && published == null) return;
    final values = <Object?>[];
    final assignments = <String>[];
    if (scanEnabled != null) {
      assignments.add('scan_enabled = ?');
      values.add(scanEnabled ? 1 : 0);
    }
    if (published != null) {
      assignments.add('published = ?');
      values.add(published ? 1 : 0);
    }
    values.add(id);
    _transaction(() {
      _db.execute(
        'UPDATE sources SET ${assignments.join(', ')} WHERE id = ?',
        values,
      );
      _advanceRevision();
    });
  }

  Map<String, dynamic> overrides() {
    final result = <String, dynamic>{};
    for (final row in _db.select('SELECT path,payload FROM manual_overrides')) {
      try {
        final decoded = jsonDecode(row['payload'] as String);
        if (decoded is Map) {
          result[row['path'] as String] = Map<String, dynamic>.from(decoded);
        }
      } catch (_) {
        // A corrupt override is ignored until explicitly replaced; it cannot
        // poison a scan or silently assign an identity.
      }
    }
    return result;
  }

  void setOverride(String sourcePath, Map<String, dynamic>? payload) =>
      _transaction(() {
        final path = canonicalPath(sourcePath);
        if (payload == null) {
          _db.execute('DELETE FROM manual_overrides WHERE path = ?', [path]);
        } else {
          _db.execute(
            '''
        INSERT INTO manual_overrides(path,payload) VALUES(?,?)
        ON CONFLICT(path) DO UPDATE SET payload=excluded.payload
      ''',
            [path, jsonEncode(payload)],
          );
        }
        // Package rows are updated only by a completed scan, so an API revision
        // never claims an override that is not yet reflected in the snapshot.
      });

  void importLegacyOverrides(Map<String, dynamic> values) {
    if (values.isEmpty) return;
    _transaction(() {
      for (final entry in values.entries) {
        if (entry.value is! Map) continue;
        final path = canonicalPath(entry.key);
        final exists = _db.select(
          'SELECT 1 FROM manual_overrides WHERE path = ?',
          [path],
        );
        if (exists.isEmpty) {
          _db.execute(
            'INSERT INTO manual_overrides(path,payload) VALUES(?,?)',
            [path, jsonEncode(entry.value)],
          );
        }
      }
    });
  }

  Future<Package?> cached(FileSource source, Map? override) async {
    final path = canonicalPath(source.path);
    final rows = _db.select('SELECT * FROM packages WHERE path = ?', [path]);
    if (rows.isEmpty) return null;
    final row = rows.single;
    if (row['source_snapshot'] != _sourceSnapshot(source) ||
        row['override_snapshot'] != _json(override)) {
      return null;
    }
    return _decodePackage(row, source);
  }

  List<IndexedPackage> packages({bool publishedOnly = false}) {
    final rows = _db.select('''
      SELECT p.*,
        MAX(CASE WHEN s.available = 1 THEN 1 ELSE 0 END) AS is_available,
        MAX(CASE WHEN s.published = 1 THEN 1 ELSE 0 END) AS is_published
      FROM packages p
      JOIN package_sources ps ON ps.package_id = p.id
      JOIN sources s ON s.id = ps.source_id
      GROUP BY p.id
      ${publishedOnly ? 'HAVING is_published = 1' : ''}
      ORDER BY p.path COLLATE NOCASE
    ''');
    return [
      for (final row in rows)
        IndexedPackage(
          _decodePackage(row, _decodeSource(row['source_snapshot'] as String)),
          available: (row['is_available'] as int) == 1,
          published: (row['is_published'] as int) == 1,
        ),
    ];
  }

  String get serverId =>
      _db
              .select('SELECT server_id FROM library_state WHERE singleton=1')
              .single['server_id']
          as String;
  int get revision =>
      _db
              .select('SELECT revision FROM library_state WHERE singleton=1')
              .single['revision']
          as int;
  String get revisionToken => 'r$revision';

  void upsertTitleMetadata(Iterable<TitleMetadata> values) => _transaction(() {
    for (final value in values) {
      _db.execute(
        '''
        INSERT INTO title_metadata(title_id,name,publisher,icon_url) VALUES(?,?,?,?)
        ON CONFLICT(title_id) DO UPDATE SET name=excluded.name,publisher=excluded.publisher,icon_url=excluded.icon_url
      ''',
        [value.id, value.name, value.publisher, value.icon],
      );
    }
    _advanceRevision();
  });

  TitleMetadata? titleMetadata(String titleId) {
    final rows = _db.select('SELECT * FROM title_metadata WHERE title_id = ?', [
      titleId,
    ]);
    if (rows.isEmpty) return null;
    final row = rows.single;
    return TitleMetadata(
      row['title_id'] as String,
      row['name'] as String,
      row['publisher'] as String,
      row['icon_url'] as String?,
    );
  }

  void commit(List<SourceScan> scans) => _transaction(() {
    var changed = false;
    var generation =
        _db
                .select(
                  'SELECT generation FROM library_state WHERE singleton=1',
                )
                .single['generation']
            as int;
    generation++;
    final now = DateTime.now().microsecondsSinceEpoch;
    for (final scan in scans) {
      final source = scan.source;
      if (!scan.complete) {
        _db.execute('UPDATE sources SET available=0,last_error=? WHERE id=?', [
          scan.result.issues.take(1).join(),
          source.id,
        ]);
        changed = true;
        continue;
      }
      _db.execute(
        '''
        UPDATE sources SET available=1,last_successful_scan=?,last_error=NULL WHERE id=?
      ''',
        [now, source.id],
      );
      for (final package in scan.result.packages) {
        final id = package.key;
        _db.execute('''
          INSERT INTO packages(
            id,path,source_snapshot,override_snapshot,title_id,evidence,group_override,
            package_group_id,package_version,kind_override,observed_at
          ) VALUES(?,?,?,?,?,?,?,?,?,?,?)
          ON CONFLICT(id) DO UPDATE SET
            path=excluded.path,source_snapshot=excluded.source_snapshot,
            override_snapshot=excluded.override_snapshot,title_id=excluded.title_id,
            evidence=excluded.evidence,group_override=excluded.group_override,
            package_group_id=excluded.package_group_id,package_version=excluded.package_version,
            kind_override=excluded.kind_override,observed_at=excluded.observed_at
        ''', _encodePackage(package, now));
        _db.execute(
          '''
          INSERT INTO package_sources(package_id,source_id,scan_generation) VALUES(?,?,?)
          ON CONFLICT(package_id,source_id) DO UPDATE SET scan_generation=excluded.scan_generation
        ''',
          [id, source.id, generation],
        );
      }
      _db.execute(
        'DELETE FROM package_sources WHERE source_id=? AND scan_generation<>?',
        [source.id, generation],
      );
      changed = true;
    }
    _db.execute(
      'DELETE FROM packages WHERE id NOT IN (SELECT package_id FROM package_sources)',
    );
    _db.execute('UPDATE library_state SET generation=? WHERE singleton=1', [
      generation,
    ]);
    if (changed) _advanceRevision();
  });

  List<Object?> _encodePackage(Package package, int observedAt) => [
    package.key,
    canonicalPath(package.source.path),
    _sourceSnapshot(package.source),
    _json(overrides()[canonicalPath(package.source.path)] as Map?),
    package.titleId,
    package.evidence.name,
    package.groupOverride,
    package.packageGroupId,
    package.packageVersion,
    package.kindOverride?.name,
    observedAt,
  ];

  Package _decodePackage(Row row, FileSource source) => Package(
    source,
    titleId: row['title_id'] as String?,
    evidence: IdentityEvidence.values.byName(row['evidence'] as String),
    groupOverride: row['group_override'] as String?,
    packageGroupId: row['package_group_id'] as String?,
    packageVersion: row['package_version'] as int?,
    kindOverride: (row['kind_override'] as String?) == null
        ? null
        : ContentKind.values.byName(row['kind_override'] as String),
  );

  String _sourceSnapshot(FileSource source) => jsonEncode({
    'path': canonicalPath(source.path),
    'segments': source.segments.map(canonicalPath).toList(),
    'sizes': source.sizes,
    'modified': source.modified,
  });

  FileSource _decodeSource(String value) {
    final decoded = jsonDecode(value) as Map<String, dynamic>;
    return FileSource(
      decoded['path'] as String,
      List<String>.from(decoded['segments'] as List),
      List<int>.from(decoded['sizes'] as List),
      List<int>.from(decoded['modified'] as List),
    );
  }

  void _advanceRevision() => _db.execute(
    'UPDATE library_state SET revision=revision+1 WHERE singleton=1',
  );
  void _transaction(void Function() action) {
    _db.execute('BEGIN IMMEDIATE');
    try {
      action();
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  Future<void> close() async => _db.dispose();
}
