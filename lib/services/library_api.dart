// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import '../core/files.dart';
import '../core/library.dart';
import 'library_service.dart';
import 'library_store.dart';
import 'network.dart';
import 'procedural_cover.dart';

class LibraryServerConfig {
  final String bindAddress;
  final int port;
  final String name;
  final String? bearerToken;
  final Directory? coverCache;
  const LibraryServerConfig({
    required this.bindAddress,
    required this.port,
    required this.name,
    this.bearerToken,
    this.coverCache,
  }) : assert(port >= 0 && port <= 65535);
}

class _Game {
  final GameGroup group;
  final List<IndexedPackage> packages;
  final String name;
  final String publisher;
  final String? coverPath;
  const _Game(
    this.group,
    this.packages,
    this.name,
    this.publisher,
    this.coverPath,
  );
}

/// Read-only Awoo gallery API. It deliberately has no filesystem browsing,
/// management, USB, payload or installation endpoints.
class LibraryApiServer {
  final LibraryService library;
  final LibraryServerConfig config;
  HttpServer? _server;
  void Function()? _unlisten;
  LibraryApiServer(this.library, this.config) {
    final token = config.bearerToken;
    if (token != null &&
        (token.isEmpty ||
            token.length > 256 ||
            RegExp(r'[\x00-\x20\x7f]').hasMatch(token))) {
      throw ArgumentError(
        'Bearer token must contain 1–256 visible ASCII characters',
      );
    }
  }

  int get port {
    final server = _server;
    if (server == null) throw StateError('Library service is not running');
    return server.port;
  }

  Future<void> start({Cancellation? cancellation}) async {
    if (_server != null) throw StateError('Library service is already running');
    final address = InternetAddress.tryParse(config.bindAddress);
    if (address == null) {
      throw ArgumentError('Bind address must be a numeric local address');
    }
    _server = await HttpServer.bind(address, config.port, shared: false);
    _unlisten = cancellation?.listen(() => unawaited(close()));
    _server!.listen((request) => unawaited(_handle(request)));
  }

  Future<void> close() async {
    _unlisten?.call();
    _unlisten = null;
    final server = _server;
    _server = null;
    await server?.close(force: true);
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    try {
      if (request.method != 'GET' && request.method != 'HEAD') {
        response.statusCode = HttpStatus.methodNotAllowed;
        response.headers.set(HttpHeaders.allowHeader, 'GET, HEAD');
        return;
      }
      if (request.uri.path == '/healthz') {
        return await _json(request, response, {
          'status': 'ok',
          'libraryRevision': library.revision,
        });
      }
      if (!_authorized(request)) {
        response.statusCode = HttpStatus.unauthorized;
        response.headers.set(HttpHeaders.wwwAuthenticateHeader, 'Bearer');
        return;
      }
      final segments = request.uri.pathSegments;
      if (segments.length < 4 ||
          segments[0] != 'api' ||
          segments[1] != 'awoo' ||
          segments[2] != 'v1') {
        response.statusCode = HttpStatus.notFound;
        return;
      }
      switch (segments[3]) {
        case 'info':
          if (segments.length != 4) {
            _notFound(response);
            return;
          }
          return await _json(request, response, _info());
        case 'games':
          if (segments.length == 4) return await _games(request, response);
          if (segments.length == 5) {
            return await _game(request, response, segments[4]);
          }
          _notFound(response);
          return;
        case 'covers':
          if (segments.length != 5) {
            _notFound(response);
            return;
          }
          return await _cover(request, response, segments[4]);
        case 'packages':
          if (segments.length != 7) {
            _notFound(response);
            return;
          }
          return await _package(
            request,
            response,
            segments[4],
            segments[5],
            segments[6],
          );
        default:
          _notFound(response);
          return;
      }
    } catch (_) {
      // The response may already be streaming. Closing it is safer than
      // attempting to append an error body to a package response.
    } finally {
      try {
        await response.close();
      } catch (_) {
        // Client disconnects are not server errors and must not stop sharing.
      }
    }
  }

  bool _authorized(HttpRequest request) {
    final expected = config.bearerToken;
    if (expected == null) return true;
    final value = request.headers.value(HttpHeaders.authorizationHeader);
    if (value == null || !value.startsWith('Bearer ')) return false;
    final candidate = value.substring('Bearer '.length);
    final left = utf8.encode(expected);
    final right = utf8.encode(candidate);
    var different = left.length ^ right.length;
    final width = left.length > right.length ? left.length : right.length;
    for (var i = 0; i < width; i++) {
      different |=
          (i < left.length ? left[i] : 0) ^ (i < right.length ? right[i] : 0);
    }
    return different == 0;
  }

  Map<String, dynamic> _envelope() => {
    'schemaVersion': 1,
    'serverId': library.serverId,
    'libraryRevision': library.revision,
  };

  Map<String, dynamic> _info() => {
    ..._envelope(),
    'name': config.name,
    'capabilities': ['library'],
  };

  List<_Game> _gamesSnapshot() {
    final indexed = library.publishedPackages;
    final byKey = {for (final item in indexed) item.package.key: item};
    final groups = groupPackages(indexed.map((item) => item.package).toList())
      ..sort((a, b) => a.id.compareTo(b.id));
    return [
      for (final group in groups)
        () {
          final metadata = library.store.titleMetadata(group.id);
          final representative = group.representative;
          return _Game(
            group,
            [for (final package in group.packages) byKey[package.key]!],
            metadata?.name ?? representative.label,
            metadata?.publisher ?? '',
            group.id,
          );
        }(),
    ];
  }

  Future<void> _games(HttpRequest request, HttpResponse response) async {
    final limit = _positive(
      request.uri.queryParameters['limit'],
      fallback: 100,
      maximum: 200,
    );
    if (limit == null) {
      await _json(request, response, {
        'error': 'invalid_limit',
      }, status: HttpStatus.badRequest);
      return;
    }
    final offset = _cursor(request.uri.queryParameters['cursor']);
    if (offset == null) return _stale(request, response);
    final games = _gamesSnapshot();
    final page = games.skip(offset).take(limit).toList();
    final next = offset + page.length < games.length
        ? '${library.revision}:${offset + page.length}'
        : '';
    await _json(request, response, {
      ..._envelope(),
      'nextCursor': next,
      'games': [
        for (final game in page)
          {
            'id': game.group.id,
            'name': game.name,
            'publisher': game.publisher,
            'coverUrl':
                '/api/awoo/v1/covers/${Uri.encodeComponent(game.coverPath!)}',
            'updateCount': game.group.count(ContentKind.update),
            'dlcCount': game.group.count(ContentKind.dlc),
          },
      ],
    });
  }

  Future<void> _game(
    HttpRequest request,
    HttpResponse response,
    String id,
  ) async {
    if (request.uri.queryParameters['revision'] != library.revision) {
      return _stale(request, response);
    }
    final game = _gamesSnapshot()
        .where((item) => item.group.id == id)
        .firstOrNull;
    if (game == null) return _notFound(response);
    await _json(request, response, {
      ..._envelope(),
      'gameId': game.group.id,
      'nextCursor': '',
      'packages': [
        for (final item in game.packages)
          {
            'id': item.package.key,
            'filename': item.package.source.name,
            'kind': item.package.kind.name,
            'format': item.package.format.toLowerCase(),
            'version': item.package.version,
            'size': item.package.source.length,
            'available': item.available,
            'downloadUrl':
                '/api/awoo/v1/packages/${item.package.key}/${_contentRevision(item.package.source)}/${Uri.encodeComponent(item.package.source.name)}',
          },
      ],
    });
  }

  Future<void> _cover(
    HttpRequest request,
    HttpResponse response,
    String id,
  ) async {
    if (!_gamesSnapshot().any((game) => game.group.id == id)) {
      return _notFound(response);
    }
    final metadata = library.store.titleMetadata(id);
    final icon = metadata?.icon;
    if (icon != null && config.coverCache != null) {
      final file = File(
        p.join(
          config.coverCache!.path,
          sha256.convert(utf8.encode(icon)).toString(),
        ),
      );
      if (await file.exists() && await file.length() <= 8 * 1024 * 1024) {
        response.headers.contentType = ContentType('image', 'png');
        response.headers.contentLength = await file.length();
        if (request.method == 'GET') await response.addStream(file.openRead());
        return;
      }
    }
    final generated = ProceduralCover.png(id);
    response.headers.contentType = ContentType('image', 'png');
    response.headers.contentLength = generated.length;
    if (request.method == 'GET') response.add(generated);
  }

  Future<void> _package(
    HttpRequest request,
    HttpResponse response,
    String id,
    String contentRevision,
    String name,
  ) async {
    final item = library.publishedPackages
        .where((value) => value.package.key == id)
        .firstOrNull;
    if (item == null ||
        !item.available ||
        item.package.source.name != name ||
        _contentRevision(item.package.source) != contentRevision) {
      return _notFound(response);
    }
    final source = item.package.source;
    if (!await _sourceIsCurrent(source)) return _stale(request, response);
    response.headers
      ..set(HttpHeaders.acceptRangesHeader, 'bytes')
      ..set(HttpHeaders.etagHeader, '"$contentRevision"')
      ..contentType = ContentType.binary;
    var range = ByteRange(0, source.length - 1);
    final header = request.headers.value(HttpHeaders.rangeHeader);
    if (header != null) {
      try {
        range = ByteRange.parse(header, source.length);
        response.statusCode = HttpStatus.partialContent;
        response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes ${range.start}-${range.end}/${source.length}',
        );
      } on FormatException {
        response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes */${source.length}',
        );
        return;
      }
    }
    response.contentLength = range.length;
    if (request.method == 'GET') {
      await response.addStream(source.read(range.start, range.length));
    }
  }

  String _contentRevision(FileSource source) => sha256
      .convert(
        utf8.encode(
          jsonEncode({
            'segments': source.segments,
            'sizes': source.sizes,
            'modified': source.modified,
          }),
        ),
      )
      .toString();

  Future<bool> _sourceIsCurrent(FileSource source) async {
    for (var index = 0; index < source.segments.length; index++) {
      final segment = source.segments[index];
      if (await FileSystemEntity.type(segment, followLinks: false) !=
          FileSystemEntityType.file) {
        return false;
      }
      final stat = await File(segment).stat();
      if (stat.size != source.sizes[index] ||
          stat.modified.microsecondsSinceEpoch != source.modified[index]) {
        return false;
      }
    }
    return true;
  }

  int? _positive(String? value, {required int fallback, required int maximum}) {
    final parsed = value == null ? fallback : int.tryParse(value);
    if (parsed == null || parsed < 1 || parsed > maximum) return null;
    return parsed;
  }

  int? _cursor(String? value) {
    if (value == null || value.isEmpty) return 0;
    final match = RegExp(r'^r(\d+):(\d+)$').firstMatch(value);
    if (match == null || 'r${match.group(1)}' != library.revision) return null;
    return int.tryParse(match.group(2)!);
  }

  Future<void> _json(
    HttpRequest request,
    HttpResponse response,
    Object value, {
    int status = HttpStatus.ok,
  }) async {
    response.statusCode = status;
    response.headers
      ..contentType = ContentType.json
      ..set(HttpHeaders.cacheControlHeader, 'no-store');
    if (request.method == 'GET') response.write(jsonEncode(value));
  }

  Future<void> _stale(HttpRequest request, HttpResponse response) => _json(
    request,
    response,
    {'error': 'stale_revision'},
    status: HttpStatus.conflict,
  );
  void _notFound(HttpResponse response) =>
      response.statusCode = HttpStatus.notFound;
}
