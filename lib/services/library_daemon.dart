// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import '../core/files.dart';
import 'library_api.dart';
import 'library_service.dart';
import 'library_store.dart';

class ConfiguredSource {
  final String path;
  final LibrarySourceKind kind;
  final bool published;
  const ConfiguredSource({
    required this.path,
    required this.kind,
    required this.published,
  });
}

class LibraryDaemonConfig {
  final Directory dataDirectory;
  final String bindAddress;
  final int port;
  final String name;
  final File? tokenFile;
  final Directory? coverCache;
  final Duration scanInterval;
  final List<ConfiguredSource> sources;
  const LibraryDaemonConfig({
    required this.dataDirectory,
    required this.bindAddress,
    required this.port,
    required this.name,
    required this.tokenFile,
    required this.coverCache,
    required this.scanInterval,
    required this.sources,
  });

  static Future<LibraryDaemonConfig> load(File file) async {
    if (!await file.exists() || await file.length() > 128 * 1024) {
      throw ArgumentError(
        'Library service config is missing or exceeds 128 KiB',
      );
    }
    final raw = jsonDecode(await file.readAsString());
    if (raw is! Map) {
      throw const FormatException('Library service config must be an object');
    }
    String requiredString(String key, {int maximum = 1024}) {
      final value = raw[key];
      if (value is! String ||
          value.isEmpty ||
          value.length > maximum ||
          value.contains(RegExp(r'[\x00-\x1f]'))) {
        throw FormatException('Invalid $key in library service config');
      }
      return value;
    }

    final dataDirectory = Directory(requiredString('dataDirectory'));
    if (!p.isAbsolute(dataDirectory.path)) {
      throw const FormatException('dataDirectory must be absolute');
    }
    final bindAddress = requiredString('bindAddress', maximum: 64);
    if (InternetAddress.tryParse(bindAddress) == null) {
      throw const FormatException('bindAddress must be a numeric address');
    }
    final port = raw['port'];
    if (port is! int || port < 1 || port > 65535) {
      throw const FormatException('port must be 1–65535');
    }
    // Directory notifications drive prompt discovery when a filesystem
    // supports them. This is the conservative fallback for NAS mounts where
    // notifications can be unavailable or can miss remote changes.
    final interval = raw['scanIntervalSeconds'] ?? 6 * 60 * 60;
    if (interval is! int || interval < 15 || interval > 24 * 60 * 60) {
      throw const FormatException('scanIntervalSeconds must be 15–86400');
    }
    File? optionalFile(String key) {
      final value = raw[key];
      if (value == null) return null;
      if (value is! String || !p.isAbsolute(value) || value.length > 1024) {
        throw FormatException('$key must be an absolute path');
      }
      return File(value);
    }

    Directory? optionalDirectory(String key) {
      final value = raw[key];
      if (value == null) return null;
      if (value is! String || !p.isAbsolute(value) || value.length > 1024) {
        throw FormatException('$key must be an absolute path');
      }
      return Directory(value);
    }

    final configured = raw['sources'] ?? const [];
    if (configured is! List || configured.length > 256) {
      throw const FormatException('sources must contain at most 256 entries');
    }
    final sources = <ConfiguredSource>[];
    final paths = <String>{};
    for (final item in configured) {
      if (item is! Map) throw const FormatException('source must be an object');
      final path = item['path'];
      final kind = item['kind'];
      if (path is! String ||
          !p.isAbsolute(path) ||
          path.length > 4096 ||
          kind is! String) {
        throw const FormatException('source path and kind are required');
      }
      final normalized = LibraryStore.canonicalPath(path);
      if (!paths.add(normalized)) {
        throw const FormatException('Duplicate source path');
      }
      sources.add(
        ConfiguredSource(
          path: normalized,
          kind: LibrarySourceKind.values.byName(kind),
          published: item['published'] is bool
              ? item['published'] as bool
              : true,
        ),
      );
    }
    return LibraryDaemonConfig(
      dataDirectory: dataDirectory,
      bindAddress: bindAddress,
      port: port,
      name: requiredString('name', maximum: 128),
      tokenFile: optionalFile('tokenFile'),
      coverCache: optionalDirectory('coverCache'),
      scanInterval: Duration(seconds: interval),
      sources: sources,
    );
  }
}

class LibraryDaemon {
  final LibraryDaemonConfig config;
  final LibraryService library;
  final LibraryApiServer server;
  final RandomAccessFile _lock;
  final Cancellation cancellation = Cancellation();
  Timer? _timer;
  Timer? _watchDebounce;
  final _watches = <StreamSubscription<FileSystemEvent>>[];
  bool _scanRunning = false;
  bool _scanQueued = false, _queuedForce = false;
  LibraryDaemon._(this.config, this.library, this.server, this._lock);

  static Future<LibraryDaemon> start(
    LibraryDaemonConfig config, {
    void Function(String message)? log,
  }) async {
    String? token;
    final tokenFile = config.tokenFile;
    if (tokenFile != null) {
      if (!await tokenFile.exists() || await tokenFile.length() > 512) {
        throw ArgumentError('tokenFile is missing or exceeds 512 bytes');
      }
      token = (await tokenFile.readAsString()).trim();
      if (token.isEmpty) throw ArgumentError('tokenFile is empty');
    }
    await config.dataDirectory.create(recursive: true);
    final lock = await File(
      p.join(config.dataDirectory.path, 'library.lock'),
    ).open(mode: FileMode.write);
    try {
      await lock.lock(FileLock.exclusive);
    } on FileSystemException {
      await lock.close();
      throw StateError(
        'Another library service owns ${config.dataDirectory.path}',
      );
    }
    try {
      final library = await LibraryService.open(config.dataDirectory);
      for (final source in config.sources) {
        library.registerSource(
          source.path,
          kind: source.kind,
          published: source.published,
        );
      }
      final daemon = LibraryDaemon._(
        config,
        library,
        LibraryApiServer(
          library,
          LibraryServerConfig(
            bindAddress: config.bindAddress,
            port: config.port,
            name: config.name,
            bearerToken: token,
            coverCache: config.coverCache,
          ),
        ),
        lock,
      );
      await daemon.server.start(cancellation: daemon.cancellation);
      daemon._timer = Timer.periodic(
        config.scanInterval,
        (_) => daemon.scan(log: log, force: true),
      );
      daemon._watchSources(log: log);
      unawaited(daemon.scan(log: log));
      log?.call(
        'Library service listening on ${config.bindAddress}:${daemon.server.port}',
      );
      return daemon;
    } catch (_) {
      await lock.close();
      rethrow;
    }
  }

  Future<void> scan({
    void Function(String message)? log,
    bool force = false,
  }) async {
    if (cancellation.cancelled) return;
    if (_scanRunning) {
      _scanQueued = true;
      _queuedForce = _queuedForce || force;
      return;
    }
    _scanRunning = true;
    try {
      final issues = await library.scan(cancel: cancellation, force: force);
      log?.call(
        issues.isEmpty
            ? 'Library scan committed ${library.revision}'
            : 'Library scan committed ${library.revision} with ${issues.length} issue(s)',
      );
    } on Cancelled {
      // Graceful shutdown preserves the prior committed revision.
    } catch (error) {
      log?.call('Library scan failed: $error');
    } finally {
      _scanRunning = false;
      if (_scanQueued && !cancellation.cancelled) {
        final queuedForce = _queuedForce;
        _scanQueued = false;
        _queuedForce = false;
        unawaited(scan(log: log, force: queuedForce));
      }
    }
  }

  void _watchSources({void Function(String message)? log}) {
    for (final source in config.sources) {
      if (source.kind != LibrarySourceKind.directory) continue;
      try {
        _watches.add(
          Directory(source.path)
              .watch(recursive: true)
              .listen(
                (_) {
                  if (cancellation.cancelled) return;
                  _watchDebounce?.cancel();
                  _watchDebounce = Timer(
                    const Duration(seconds: 2),
                    () => unawaited(scan(log: log, force: true)),
                  );
                },
                onError: (Object error) {
                  log?.call(
                    'Library watch unavailable for ${source.path}: $error; periodic scan remains enabled',
                  );
                },
              ),
        );
      } catch (error) {
        log?.call(
          'Library watch unavailable for ${source.path}: $error; periodic scan remains enabled',
        );
      }
    }
  }

  Future<void> close() async {
    cancellation.cancel();
    _timer?.cancel();
    _watchDebounce?.cancel();
    await Future.wait([for (final watch in _watches) watch.cancel()]);
    await server.close();
    await library.close();
    await _lock.close();
  }
}
