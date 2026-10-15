// SPDX-License-Identifier: GPL-3.0-or-later
// Awoo framing adapted from NS-USBloader, Copyright Dmitry Isaenko.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import '../core/files.dart';
import '../core/library.dart';

class ByteRange {
  final int start, end;
  ByteRange(this.start, this.end);
  int get length => end - start + 1;
  static ByteRange parse(String value, int size) {
    final m = RegExp(r'^bytes=(\d*)-(\d*)$').firstMatch(value.trim());
    if (m == null || size <= 0 || (m[1]!.isEmpty && m[2]!.isEmpty)) {
      throw const FormatException('Invalid range');
    }
    if (m[1]!.isEmpty) {
      final suffix = int.parse(m[2]!);
      if (suffix <= 0) throw const FormatException('Invalid suffix');
      return ByteRange(suffix >= size ? 0 : size - suffix, size - 1);
    }
    final start = int.parse(m[1]!);
    final end = m[2]!.isEmpty ? size - 1 : int.parse(m[2]!);
    if (start >= size || end < start) {
      throw const FormatException('Unsatisfiable range');
    }
    return ByteRange(start, end >= size ? size - 1 : end);
  }
}

/// Counts the union of ranges; repeated probes do not inflate progress.
class Coverage {
  final List<(int, int)> _ranges = [];
  void add(int start, int end) {
    _ranges.add((start, end));
    _ranges.sort((a, b) => a.$1.compareTo(b.$1));
    final merged = <(int, int)>[];
    for (final range in _ranges) {
      if (merged.isEmpty || range.$1 > merged.last.$2) {
        merged.add(range);
      } else if (range.$2 > merged.last.$2) {
        merged[merged.length - 1] = (merged.last.$1, range.$2);
      }
    }
    _ranges
      ..clear()
      ..addAll(merged);
  }

  int get bytes => _ranges.fold(0, (sum, r) => sum + r.$2 - r.$1);
}

class NetworkTransfer {
  final List<ManifestEntry> entries;
  final Cancellation cancellation;
  final void Function(int, int)? onProgress;
  final void Function(String)? onError;
  final _coverage = <String, Coverage>{};
  HttpServer? _server;
  void Function()? _unlisten;
  bool advertised = false;
  NetworkTransfer(
    this.entries,
    this.cancellation, {
    this.onProgress,
    this.onError,
  });
  int get port => _server!.port;
  int get total => entries.fold(0, (s, e) => s + e.source.length);
  int get served => _coverage.values.fold(0, (s, c) => s + c.bytes);
  bool get allBytesServed => served == total;
  Future<void> serve(String bind, {int port = 0}) async {
    if (entries.isEmpty) throw ArgumentError('Select files first');
    cancellation.check();
    _server = await HttpServer.bind(bind, port);
    _unlisten = cancellation.listen(() => unawaited(close()));
    _server!.listen((request) => unawaited(_handle(request)));
    cancellation.check();
  }

  /// Upstream Awoo expects host:port/path lines, without the http:// prefix.
  Future<void> advertise(
    String console,
    String host, {
    int consolePort = 2000,
  }) async {
    cancellation.check();
    if (_server == null) throw StateError('Bind before advertising');
    final address = InternetAddress.tryParse(host);
    if (address == null || address.rawAddress.every((byte) => byte == 0)) {
      throw ArgumentError('Choose a reachable host IP address');
    }
    final authority = address.type == InternetAddressType.IPv6
        ? '[$host]'
        : host;
    final urls = entries
        .map((e) => '$authority:$port/${e.id}/${Uri.encodeComponent(e.name)}\n')
        .join();
    final payload = utf8.encode(urls);
    if (payload.length > 1024 * 1024) {
      throw ArgumentError('Transfer list is too large');
    }
    final socket = await Socket.connect(
      console,
      consolePort,
      timeout: const Duration(seconds: 5),
    );
    final remove = cancellation.listen(socket.destroy);
    try {
      cancellation.check();
      socket.add(
        (ByteData(
          4,
        )..setUint32(0, payload.length, Endian.big)).buffer.asUint8List(),
      );
      socket.add(payload);
      await socket.flush();
      cancellation.check();
      advertised = true;
    } finally {
      remove();
      socket.destroy();
    }
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    try {
      cancellation.check();
      if (request.method != 'GET' && request.method != 'HEAD') {
        response.statusCode = 405;
        response.headers.set('Allow', 'GET, HEAD');
        return;
      }
      final parts = request.uri.pathSegments;
      final entry = parts.length == 2
          ? entries
                .where((e) => e.id == parts[0] && e.name == parts[1])
                .firstOrNull
          : null;
      if (entry == null) {
        response.statusCode = 404;
        return;
      }
      final size = entry.source.length;
      response.headers
        ..set('Accept-Ranges', 'bytes')
        ..contentType = ContentType.binary;
      var range = ByteRange(0, size - 1);
      final header = request.headers.value('range');
      if (header != null) {
        try {
          range = ByteRange.parse(header, size);
        } catch (_) {
          response.statusCode = 416;
          response.headers.set('Content-Range', 'bytes */$size');
          return;
        }
        response.statusCode = 206;
        response.headers.set(
          'Content-Range',
          'bytes ${range.start}-${range.end}/$size',
        );
      }
      response.contentLength = range.length;
      if (request.method == 'HEAD') return;
      await response.addStream(
        entry.source.read(range.start, range.length, cancel: cancellation),
      );
      await response.flush();
      cancellation.check();
      _coverage
          .putIfAbsent(entry.id, () => Coverage())
          .add(range.start, range.end + 1);
      onProgress?.call(served, total);
    } on Cancelled {
      /* The session status remains cancelled. */
    } catch (e) {
      onError?.call(e.toString());
      try {
        response.statusCode = 500;
      } catch (_) {
        /* Headers already sent. */
      }
    } finally {
      try {
        await response.close();
      } catch (_) {
        /* Peer disconnected. */
      }
    }
  }

  Future<void> close() async {
    _unlisten?.call();
    _unlisten = null;
    final server = _server;
    _server = null;
    await server?.close(force: true);
  }
}
