// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:crypto/crypto.dart';
import 'dart:convert';
import 'files.dart';
import 'package_metadata.dart';

enum ContentKind { base, update, dlc, unknown }

enum IdentityEvidence { package, filename, manual, unknown }

String? normalizeId(String? value) =>
    value != null && RegExp(r'^[0-9a-fA-F]{16}$').hasMatch(value)
    ? value.toUpperCase()
    : null;

/// Finds explicit Title IDs in a package filename without using directory or
/// game-name guesses. Compact dump names may immediately append APP, UPD or
/// DLC after the 16 hexadecimal characters, so those markers are accepted as
/// a deliberate boundary as well.
Set<String> filenameTitleIds(String filename) {
  final ids = <String>{};
  for (final match in RegExp(
    r'(?<![0-9a-fA-F])([0-9a-fA-F]{16})(?![0-9a-fA-F])',
  ).allMatches(filename)) {
    ids.add(match.group(1)!.toUpperCase());
  }
  for (final match in RegExp(
    r'(?<![0-9a-fA-F])(0100[0-9a-fA-F]{12})(?=(?:APP|UPD|DLC)(?:[v._-]|\d|$))',
    caseSensitive: false,
  ).allMatches(filename)) {
    ids.add(match.group(1)!.toUpperCase());
  }
  return ids;
}

/// Standard application ID relationships; never applied to a guessed name.
(String, ContentKind) classifyId(String id) {
  final n = BigInt.parse(id, radix: 16);
  final low = (n & BigInt.from(0x1fff)).toInt();
  if (low == 0) return (id, ContentKind.base);
  if (low == 0x800) {
    return (
      (n - BigInt.from(0x800)).toRadixString(16).padLeft(16, '0').toUpperCase(),
      ContentKind.update,
    );
  }
  if (low > 0x1000) {
    return (
      (n - BigInt.from(low)).toRadixString(16).padLeft(16, '0').toUpperCase(),
      ContentKind.dlc,
    );
  }
  return (id, ContentKind.unknown);
}

class Package {
  final FileSource source;
  final String? titleId;
  final IdentityEvidence evidence;
  final String? groupOverride;
  final String? packageGroupId;
  final int? packageVersion;
  final ContentKind? kindOverride;
  Package(
    this.source, {
    this.titleId,
    this.evidence = IdentityEvidence.unknown,
    this.groupOverride,
    this.packageGroupId,
    this.packageVersion,
    this.kindOverride,
  });
  String get key => sha256.convert(utf8.encode(source.path)).toString();
  String get label => p
      .basenameWithoutExtension(source.name)
      .replaceAll(RegExp(r'\[[^\]]*\]'), '')
      .trim();
  String get format =>
      p.extension(source.name).replaceFirst('.', '').toUpperCase();
  String get version =>
      packageVersion?.toString() ??
      RegExp(
        r'\[v(\d+)\]',
        caseSensitive: false,
      ).firstMatch(source.name)?.group(1) ??
      '—';
  ContentKind get kind =>
      kindOverride ??
      (titleId == null ? ContentKind.unknown : classifyId(titleId!).$2);
  String get groupId =>
      groupOverride ??
      packageGroupId ??
      (titleId == null ? 'file:$key' : classifyId(titleId!).$1);
}

class GameGroup {
  final String id;
  final List<Package> packages;
  GameGroup(this.id, this.packages);
  bool get orphan => !packages.any((p) => p.kind == ContentKind.base);
  int count(ContentKind kind) => packages.where((p) => p.kind == kind).length;
  Package get representative => packages.firstWhere(
    (p) => p.kind == ContentKind.base,
    orElse: () => packages.first,
  );
}

List<GameGroup> groupPackages(List<Package> packages) {
  final groups = <String, List<Package>>{};
  for (final package in packages) {
    groups.putIfAbsent(package.groupId, () => []).add(package);
  }
  return groups.entries.map((e) => GameGroup(e.key, e.value)).toList();
}

class ScanResult {
  final List<Package> packages;
  final List<String> issues;
  ScanResult(this.packages, this.issues);
}

class LibraryScanner {
  /// Bump when filename or bounded plaintext metadata interpretation changes.
  /// Persistent snapshots from earlier rules are then rescanned once.
  static const cacheVersion = 2;
  final _cache = <String, Package>{};
  final _overrideSignatures = <String, String>{};
  static bool supported(String path) =>
      RegExp(r'\.(nsp|xci|nsz|xcz)$', caseSensitive: false).hasMatch(path);
  Future<ScanResult> scan(
    List<String> roots, {
    Cancellation? cancel,
    Map<String, dynamic> overrides = const {},
    Future<Package?> Function(FileSource source, Map? override)? cached,
  }) async {
    final packages = <String, Package>{};
    final issues = <String>[];
    final visited = <String>{};
    Future<void> visit(String path) async {
      cancel?.check();
      try {
        final type = await FileSystemEntity.type(path, followLinks: false);
        if (type == FileSystemEntityType.link) return;
        final canonical = p.normalize(p.absolute(path));
        if (!visited.add(canonical)) return;
        if (supported(path)) {
          final source = await FileSource.open(path);
          final previous = _cache[canonical];
          final override = overrides[canonical] as Map?;
          final persisted = await cached?.call(source, override);
          if (persisted != null) {
            packages[canonical] = persisted;
            _cache[canonical] = persisted;
            _overrideSignatures[canonical] = jsonEncode(override);
            return;
          }
          if (previous != null &&
              _overrideSignatures[canonical] == jsonEncode(override) &&
              previous.source.modified.join(',') == source.modified.join(',') &&
              previous.source.sizes.join(',') == source.sizes.join(',')) {
            packages[canonical] = previous;
            return;
          }
          final matches = filenameTitleIds(source.name);
          final manual = normalizeId(override?['titleId'] as String?);
          final readable = await readPlaintextMetadata(source);
          final id =
              manual ??
              readable?.titleId ??
              (matches.length == 1 ? matches.single : null);
          final package = Package(
            source,
            titleId: id,
            evidence: manual != null
                ? IdentityEvidence.manual
                : readable != null
                ? IdentityEvidence.package
                : id != null
                ? IdentityEvidence.filename
                : IdentityEvidence.unknown,
            packageGroupId: manual == null ? readable?.applicationId : null,
            packageVersion: readable?.version,
            groupOverride: normalizeId(override?['groupId'] as String?),
            kindOverride:
                ContentKind.values
                    .where((k) => k.name == override?['kind'])
                    .firstOrNull ??
                (readable == null
                    ? null
                    : switch (readable.type) {
                        0x80 => ContentKind.base,
                        0x81 => ContentKind.update,
                        0x82 => ContentKind.dlc,
                        _ => ContentKind.unknown,
                      }),
          );
          packages[canonical] = package;
          _cache[canonical] = package;
          _overrideSignatures[canonical] = jsonEncode(override);
        } else if (type == FileSystemEntityType.directory) {
          await for (final item in Directory(path).list(followLinks: false)) {
            await visit(item.path);
          }
        }
      } on Cancelled {
        rethrow;
      } catch (e) {
        issues.add('$path: $e');
      }
    }

    for (final root in roots) {
      await visit(root);
    }
    _cache.removeWhere((key, _) => !packages.containsKey(key));
    final sorted = packages.values.toList()
      ..sort((a, b) => a.source.path.compareTo(b.source.path));
    return ScanResult(sorted, issues);
  }
}

class ManifestEntry {
  final String id;
  final String name;
  final FileSource source;
  ManifestEntry(this.id, this.name, this.source);
}

List<ManifestEntry> manifest(Iterable<Package> selection) {
  final seen = <String>{};
  return [
    for (final item in selection)
      if (seen.add(item.key))
        ManifestEntry(
          item.key,
          '${item.key.substring(0, 12)}_${item.source.name.replaceAll(RegExp(r'[\r\n\x00/\\]'), '_')}',
          item.source,
        ),
  ];
}
