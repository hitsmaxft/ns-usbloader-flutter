// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import '../core/files.dart';

class DownloadResult {
  final int status;
  final String? etag;
  DownloadResult(this.status, this.etag);
}

class MemoryDownload extends DownloadResult {
  final Uint8List? bytes;
  MemoryDownload(super.status, super.etag, this.bytes);
}

class Downloader {
  final bool allowHttp;
  Downloader({this.allowHttp = false});
  Future<HttpClientResponse> _get(
    HttpClient client,
    Uri uri,
    String? etag,
  ) async {
    var current = uri;
    HttpClientResponse? response;
    for (var redirects = 0; redirects <= 5; redirects++) {
      if (current.scheme != 'https' && !allowHttp) {
        throw const HttpException('Insecure redirect');
      }
      final request = await client
          .getUrl(current)
          .timeout(const Duration(seconds: 20));
      request.followRedirects = false;
      request.headers
        ..set('User-Agent', 'NS-USBloader-Flutter')
        ..set('Accept', 'application/json, application/octet-stream');
      if (etag != null && current == uri) {
        request.headers.set('If-None-Match', etag);
      }
      response = await request.close().timeout(const Duration(seconds: 20));
      if ([301, 302, 303, 307, 308].contains(response.statusCode)) {
        final location = response.headers.value('location');
        if (location == null) {
          throw const HttpException('Missing redirect target');
        }
        current = current.resolve(location);
        await response.drain<void>();
        continue;
      }
      break;
    }
    if (response == null) throw const HttpException('Missing response');
    if (response.statusCode == 304) return response;
    if (response.statusCode != 200) {
      if (response.statusCode == 403 &&
          response.headers.value('x-ratelimit-remaining') == '0') {
        final reset = int.tryParse(
          response.headers.value('x-ratelimit-reset') ?? '',
        );
        throw HttpException(
          'GitHub API rate limit reached${reset == null ? '' : '; retry after ${DateTime.fromMillisecondsSinceEpoch(reset * 1000).toLocal()}'}',
        );
      }
      throw HttpException('HTTP ${response.statusCode}');
    }
    return response;
  }

  /// Keeps unfiltered catalog input in memory; only allowlisted output is saved.
  Future<MemoryDownload> memory(
    Uri uri, {
    required int maxBytes,
    String? etag,
    Cancellation? cancel,
  }) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    final remove = cancel?.listen(() => client.close(force: true));
    try {
      cancel?.check();
      final response = await _get(client, uri, etag);
      if (response.statusCode == 304) return MemoryDownload(304, etag, null);
      if (response.contentLength > maxBytes) {
        throw const HttpException('Download exceeds size limit');
      }
      final buffer = BytesBuilder(copy: false);
      await for (final chunk in response.timeout(const Duration(seconds: 30))) {
        cancel?.check();
        if (buffer.length + chunk.length > maxBytes) {
          throw const HttpException('Download exceeds size limit');
        }
        buffer.add(chunk);
      }
      cancel?.check();
      return MemoryDownload(
        200,
        response.headers.value('etag'),
        buffer.takeBytes(),
      );
    } finally {
      remove?.call();
      client.close(force: true);
    }
  }

  Future<DownloadResult> fetch(
    Uri uri,
    File target, {
    required int maxBytes,
    Cancellation? cancel,
    String? sha256Digest,
    String? etag,
    int? expectedSize,
  }) async {
    if (uri.scheme != 'https' && !allowHttp) {
      throw ArgumentError('HTTPS required');
    }
    await target.parent.create(recursive: true);
    final staging = await target.parent.createTemp('.download-');
    final partial = File(p.join(staging.path, 'partial'));
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15)
      ..autoUncompress = true;
    final remove = cancel?.listen(() => client.close(force: true));
    try {
      cancel?.check();
      final response = await _get(client, uri, etag);
      if (response.statusCode == 304) return DownloadResult(304, etag);
      if (response.contentLength > maxBytes) {
        throw const HttpException('Download exceeds size limit');
      }
      final sink = partial.openWrite();
      var received = 0;
      try {
        await for (final chunk in response.timeout(
          const Duration(seconds: 30),
        )) {
          cancel?.check();
          received += chunk.length;
          if (received > maxBytes) {
            throw const HttpException('Download exceeds size limit');
          }
          sink.add(chunk);
          // Bound the file sink queue even on a slow external drive.
          await sink.flush();
        }
      } finally {
        await sink.close();
      }
      cancel?.check();
      if (expectedSize != null && received != expectedSize) {
        throw const FormatException('Download size mismatch');
      }
      if (sha256Digest != null) {
        final digest = await sha256.bind(partial.openRead()).first;
        if (digest.toString() != sha256Digest.toLowerCase()) {
          throw const FormatException('SHA-256 mismatch');
        }
      }
      await partial.rename(target.path);
      return DownloadResult(200, response.headers.value('etag'));
    } finally {
      remove?.call();
      client.close(force: true);
      await staging.delete(recursive: true);
    }
  }
}

enum PayloadProject { hekate, fusee }

class PayloadRelease {
  final PayloadProject project;
  final String tag, name;
  final Uri url;
  final int size;
  final String? digest;
  PayloadRelease(
    this.project,
    this.tag,
    this.name,
    this.url,
    this.size,
    this.digest,
  );
  Map<String, dynamic> toJson() => {
    'project': project.name,
    'tag': tag,
    'name': name,
    'url': url.toString(),
    'size': size,
    'digest': digest,
  };
  factory PayloadRelease.fromJson(Map<String, dynamic> j) => PayloadRelease(
    PayloadProject.values.byName(j['project']),
    j['tag'],
    j['name'],
    Uri.parse(j['url']),
    j['size'],
    j['digest'],
  );
}

class PayloadProvider {
  final Directory cache;
  final Downloader downloader;
  String? releaseWarning;
  PayloadProvider(this.cache, {Downloader? downloader})
    : downloader = downloader ?? Downloader();
  static List<PayloadRelease> parse(
    PayloadProject project,
    List<dynamic> releases,
  ) {
    final result = <PayloadRelease>[];
    for (final release in releases.whereType<Map>()) {
      if (release['draft'] == true) continue;
      for (final asset in (release['assets'] as List? ?? []).whereType<Map>()) {
        final name = asset['name'] as String? ?? '';
        final wanted = project == PayloadProject.hekate
            ? RegExp(r'^hekate_ctcaer_\d+(?:\.\d+)+\.bin$').hasMatch(name)
            : name == 'fusee.bin';
        if (!wanted) continue;
        final uri = Uri.tryParse(asset['browser_download_url'] ?? '');
        final repo = project == PayloadProject.hekate
            ? 'CTCaer/hekate'
            : 'Atmosphere-NX/Atmosphere';
        if (uri == null ||
            uri.scheme != 'https' ||
            uri.host != 'github.com' ||
            !uri.path.startsWith('/$repo/releases/download/')) {
          continue;
        }
        final size = asset['size'] as int? ?? 0;
        if (size < 16384 || size > 126296) continue;
        final digest = asset['digest'] as String?;
        result.add(
          PayloadRelease(
            project,
            release['tag_name'] as String,
            name,
            uri,
            size,
            digest != null &&
                    RegExp(r'^sha256:[0-9a-fA-F]{64}$').hasMatch(digest)
                ? digest.substring(7)
                : null,
          ),
        );
      }
    }
    return result;
  }

  Future<List<PayloadRelease>> releases(
    PayloadProject project, {
    Cancellation? cancel,
  }) async {
    final repo = project == PayloadProject.hekate
        ? 'CTCaer/hekate'
        : 'Atmosphere-NX/Atmosphere';
    final file = File(p.join(cache.path, '${project.name}-releases.json'));
    releaseWarning = null;
    final etagFile = File('${file.path}.etag');
    try {
      final response = await downloader.fetch(
        Uri.https('api.github.com', '/repos/$repo/releases', {
          'per_page': '30',
        }),
        file,
        maxBytes: 4 * 1024 * 1024,
        cancel: cancel,
        etag: await file.exists() && await etagFile.exists()
            ? await etagFile.readAsString()
            : null,
      );
      if (response.etag != null) await etagFile.writeAsString(response.etag!);
    } on Cancelled {
      rethrow;
    } catch (e) {
      cancel?.check();
      if (!await file.exists()) rethrow;
      releaseWarning = 'Using saved release list · $e';
    }
    return parse(project, jsonDecode(await file.readAsString()) as List);
  }

  File fileFor(PayloadRelease release) {
    // A digest of the complete release identity avoids path traversal and tag collisions.
    final key = sha256
        .convert(
          utf8.encode('${release.project.name}/${release.tag}/${release.name}'),
        )
        .toString();
    return File(p.join(cache.path, key, release.name));
  }

  Future<File> download(PayloadRelease release, {Cancellation? cancel}) async {
    final file = fileFor(release);
    cancel?.check();
    if (await file.exists() && await file.length() == release.size) {
      final recorded = File('${file.path}.json');
      if (await recorded.exists()) {
        final metadata = jsonDecode(await recorded.readAsString()) as Map;
        final hash = (await sha256.bind(file.openRead()).first).toString();
        if (hash == metadata['localSha256'] &&
            (release.digest == null || hash == release.digest)) {
          return file;
        }
      }
    }
    await downloader.fetch(
      release.url,
      file,
      maxBytes: 126296,
      expectedSize: release.size,
      sha256Digest: release.digest,
      cancel: cancel,
    );
    final hash = (await sha256.bind(file.openRead()).first).toString();
    await File('${file.path}.json').writeAsString(
      jsonEncode({
        ...release.toJson(),
        'localSha256': hash,
        'verifiedPublishedDigest': release.digest != null,
      }),
    );
    return file;
  }

  Future<List<(PayloadRelease, File)>> cached() async {
    final items = <(PayloadRelease, File)>[];
    if (!await cache.exists()) return items;
    await for (final entry in cache.list(recursive: true, followLinks: false)) {
      if (entry is File && entry.path.endsWith('.bin.json')) {
        try {
          final release = PayloadRelease.fromJson(
            jsonDecode(await entry.readAsString()),
          );
          final file = fileFor(release);
          if (await file.exists()) items.add((release, file));
        } catch (_) {
          /* Ignore incomplete cache records. */
        }
      }
    }
    return items;
  }
}
