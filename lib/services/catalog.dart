// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'package:path/path.dart' as p;
import 'package:crypto/crypto.dart';
import '../core/files.dart';
import '../core/library.dart';
import 'downloads.dart';

class TitleMetadata {
  final String id, name, publisher;
  final String? icon;
  TitleMetadata(this.id, this.name, this.publisher, this.icon);
  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'publisher': publisher,
    'icon': icon,
  };
  factory TitleMetadata.fromJson(Map<String, dynamic> j) =>
      TitleMetadata(j['id'], j['name'], j['publisher'] ?? '', j['icon']);
}

/// Only display fields cross the import boundary. No key or rights data retained.
Map<String, TitleMetadata> compactCatalog(Map<String, dynamic> raw) {
  final out = <String, TitleMetadata>{};
  for (final value in raw.values.whereType<Map>()) {
    final id = normalizeId(value['id'] as String?);
    final name = value['name'] as String?;
    if (id == null || name == null || name.isEmpty) continue;
    final url = value['iconUrl'] as String? ?? value['frontBoxArt'] as String?;
    final uri = url == null ? null : Uri.tryParse(url);
    out[id] = TitleMetadata(
      id,
      name,
      value['publisher'] as String? ?? '',
      uri?.scheme == 'https' ? url : null,
    );
  }
  return out;
}

class Catalog {
  final Map<String, TitleMetadata> titles;
  Catalog([Map<String, TitleMetadata>? titles]) : titles = titles ?? {};
  TitleMetadata? forGroup(GameGroup group) =>
      titles[group.id] ?? titles[group.representative.titleId];
  List<TitleMetadata> suggestions(String query) {
    final words = query
        .toLowerCase()
        .split(RegExp(r'[^a-z0-9\u3400-\u9fff]+'))
        .where((s) => s.length > 1)
        .toList();
    if (words.isEmpty) return [];
    final candidates = titles.values
        .where((t) => words.every((w) => t.name.toLowerCase().contains(w)))
        .take(30)
        .toList();
    candidates.sort((a, b) => a.name.compareTo(b.name));
    return candidates;
  }
}

class CatalogStore {
  final Directory directory;
  final Downloader downloader;
  static const regions = [
    'US.en',
    'HK.zh',
    'CN.zh',
    'JP.ja',
    'GB.en',
    'DE.de',
    'FR.fr',
    'ES.es',
  ];
  CatalogStore(this.directory, {Downloader? downloader})
    : downloader = downloader ?? Downloader();
  File _index(String region) =>
      File(p.join(directory.path, '$region.compact.json'));
  Future<Catalog> load(String region, {String fallback = 'US.en'}) async {
    final titles = <String, TitleMetadata>{};
    for (final locale in {fallback, region}) {
      final file = _index(locale);
      if (!await file.exists()) continue;
      try {
        final path = file.path;
        final parsed = await Isolate.run(
          () =>
              jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>,
        );
        titles.addAll(
          parsed.map(
            (key, value) => MapEntry(key, TitleMetadata.fromJson(value)),
          ),
        );
      } catch (_) {
        /* A corrupt cache can be replaced by Refresh. */
      }
    }
    return Catalog(titles);
  }

  Future<void> refresh(String region, {Cancellation? cancel}) async {
    if (!regions.contains(region)) throw ArgumentError('Unsupported region');
    await directory.create(recursive: true);
    final etagFile = File(p.join(directory.path, '$region.etag'));
    final etag = await etagFile.exists() && await _index(region).exists()
        ? await etagFile.readAsString()
        : null;
    final staging = await directory.createTemp('.catalog-');
    try {
      final result = await downloader.memory(
        Uri.https(
          'raw.githubusercontent.com',
          '/blawar/titledb/master/$region.json',
        ),
        maxBytes: 160 * 1024 * 1024,
        etag: etag,
        cancel: cancel,
      );
      if (result.status == 304) return;
      final transfer = TransferableTypedData.fromList([result.bytes!]);
      final compact = await Isolate.run(() {
        try {
          return jsonEncode(
            compactCatalog(
              jsonDecode(utf8.decode(transfer.materialize().asUint8List()))
                  as Map<String, dynamic>,
            ).map((key, value) => MapEntry(key, value.toJson())),
          );
        } catch (_) {
          // JSON decoder errors can include source excerpts; never expose them.
          throw const FormatException(
            'Title DB response is not a supported catalog',
          );
        }
      });
      cancel?.check();
      final next = File(p.join(staging.path, 'compact.json'));
      await next.writeAsString(compact);
      await next.rename(_index(region).path);
      if (result.etag != null) await etagFile.writeAsString(result.etag!);
    } finally {
      await staging.delete(recursive: true);
    }
  }

  final _covers = <String, Future<File?>>{};
  Future<File?> cover(String? url) {
    if (url == null) return Future.value();
    return _covers.putIfAbsent(url, () async {
      final uri = Uri.tryParse(url);
      if (uri == null || uri.scheme != 'https') return null;
      final file = File(
        p.join(
          directory.path,
          'covers',
          sha256.convert(utf8.encode(url)).toString(),
        ),
      );
      try {
        if (!await file.exists()) {
          await downloader.fetch(uri, file, maxBytes: 8 * 1024 * 1024);
        }
        return file;
      } catch (_) {
        return null;
      }
    });
  }
}

class Preferences {
  final File file;
  List<String> folders = [];
  String region = 'US.en';
  bool englishFallback = true;
  Map<String, dynamic> overrides = {};
  Preferences(this.file);
  Future<void> load() async {
    if (!await file.exists()) return;
    final j = jsonDecode(await file.readAsString()) as Map;
    folders = List<String>.from(j['folders'] ?? []);
    region = j['region'] as String? ?? 'US.en';
    englishFallback = j['englishFallback'] as bool? ?? true;
    overrides = Map<String, dynamic>.from(j['overrides'] ?? {});
  }

  Future<void> save() async {
    await file.parent.create(recursive: true);
    final staging = await file.parent.createTemp('.preferences-');
    try {
      final next = File(p.join(staging.path, 'next'));
      await next.writeAsString(
        jsonEncode({
          'folders': folders,
          'region': region,
          'englishFallback': englishFallback,
          'overrides': overrides,
        }),
      );
      await next.rename(file.path);
    } finally {
      await staging.delete(recursive: true);
    }
  }
}
