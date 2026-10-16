// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';
import 'dart:io';
import '../core/files.dart';
import '../core/library.dart';
import 'library_store.dart';
import 'catalog.dart';

/// Shared GUI/CLI/NAS library coordinator. It owns no UI and performs no USB
/// work, so the same class can run as a Linux service.
class LibraryService {
  final LibraryStore store;
  final LibraryScanner _scanner;
  bool _scanning = false;
  LibraryService._(this.store, this._scanner);

  static Future<LibraryService> open(Directory dataDirectory) async =>
      LibraryService._(
        await LibraryStore.open(dataDirectory),
        LibraryScanner(),
      );

  List<LibrarySource> get sources => store.sources();
  List<IndexedPackage> get packages => store.packages();
  List<IndexedPackage> get publishedPackages =>
      store.packages(publishedOnly: true);
  String get serverId => store.serverId;
  String get revision => store.revisionToken;
  bool get scanning => _scanning;

  Future<LibrarySource> addSource(String path, {bool published = true}) =>
      store.addSource(path, published: published);
  LibrarySource registerSource(
    String path, {
    required LibrarySourceKind kind,
    bool published = true,
  }) => store.registerSource(path, kind: kind, published: published);

  void removeSource(String id) => store.removeSource(id);
  void updateSource(String id, {bool? scanEnabled, bool? published}) =>
      store.updateSource(id, scanEnabled: scanEnabled, published: published);
  void setOverride(Package package, Map<String, dynamic>? payload) =>
      store.setOverride(package.source.path, payload);
  void updateTitleMetadata(Catalog catalog) =>
      store.upsertTitleMetadata(catalog.titles.values);

  Future<void> migrateLegacy({
    required Iterable<String> folders,
    required Map<String, dynamic> overrides,
  }) async {
    store.importLegacyOverrides(overrides);
    for (final folder in folders) {
      // The legacy preference may outlive a disconnected network mount. The
      // source is retained as unavailable rather than removed during migration.
      final normal = LibraryStore.canonicalPath(folder);
      final existing = sources.where((source) => source.path == normal);
      if (existing.isNotEmpty) continue;
      final type = await FileSystemEntity.type(normal, followLinks: false);
      if (type == FileSystemEntityType.directory ||
          type == FileSystemEntityType.file) {
        await addSource(normal);
      }
    }
  }

  /// A cancelled or inaccessible scan leaves the last committed package set
  /// intact. Only a complete source enumeration reconciles removed paths.
  Future<List<String>> scan({Cancellation? cancel, bool force = false}) async {
    if (_scanning) throw StateError('A library scan is already running');
    _scanning = true;
    try {
      final overrides = store.overrides();
      final scans = <SourceScan>[];
      final allIssues = <String>[];
      for (final source in store.sources(enabledOnly: true)) {
        cancel?.check();
        final type = await FileSystemEntity.type(
          source.path,
          followLinks: false,
        );
        final expected = source.kind == LibrarySourceKind.directory
            ? FileSystemEntityType.directory
            : FileSystemEntityType.file;
        if (type != expected) {
          final issue = '${source.path}: source unavailable or changed type';
          scans.add(
            SourceScan(
              source,
              ScanResult(const [], [issue]),
              complete: false,
              rootSnapshot: source.rootSnapshot ?? '',
            ),
          );
          allIssues.add(issue);
          continue;
        }
        final rootSnapshot = await _snapshot(source.path);
        final known = store.packagesForSource(source.id);
        final refreshKnown =
            source.scanRulesVersion != LibraryScanner.cacheVersion ||
            store.sourceOverridesChanged(source.id, overrides);
        if (!force &&
            source.rootSnapshot != null &&
            !refreshKnown &&
            source.rootSnapshot == rootSnapshot) {
          continue;
        }
        final result =
            !force &&
                known.isNotEmpty &&
                (source.rootSnapshot == null || refreshKnown)
            ? await _scanner.refresh(
                known,
                cancel: cancel,
                overrides: overrides,
              )
            : await _scanner.scan(
                [source.path],
                cancel: cancel,
                overrides: overrides,
                cached: store.cached,
              );
        // A scanner exception is represented as an issue. It is unsafe to use
        // that incomplete walk as proof that unrelated files were deleted.
        final complete = result.issues.isEmpty;
        scans.add(
          SourceScan(
            source,
            result,
            complete: complete,
            rootSnapshot: rootSnapshot,
          ),
        );
        allIssues.addAll(result.issues);
      }
      cancel?.check();
      if (scans.isNotEmpty) store.commit(scans);
      return allIssues;
    } finally {
      _scanning = false;
    }
  }

  Future<void> close() => store.close();

  Future<String> _snapshot(String path) async {
    final stat = await FileStat.stat(path);
    return jsonEncode({
      'size': stat.size,
      'modified': stat.modified.microsecondsSinceEpoch,
      'type': stat.type.toString(),
    });
  }
}
