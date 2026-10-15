import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ns_usbloader/core/files.dart';
import 'package:ns_usbloader/services/catalog.dart';
import 'package:ns_usbloader/services/downloads.dart';

class CatalogFixtureDownloader extends Downloader {
  int calls = 0;
  @override
  Future<MemoryDownload> memory(
    Uri uri, {
    required int maxBytes,
    String? etag,
    Cancellation? cancel,
  }) async {
    calls++;
    if (etag == 'fixture') return MemoryDownload(304, etag, null);
    return MemoryDownload(
      200,
      'fixture',
      Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            'nsuid': {
              'id': '0100000000002000',
              'name': 'Orbit Garden',
              'publisher': 'Fixture',
              'key': 'NEVER-PERSIST',
              'rightsId': 'NEVER-PERSIST',
            },
          }),
        ),
      ),
    );
  }

  @override
  Future<DownloadResult> fetch(
    Uri uri,
    File target, {
    required int maxBytes,
    Cancellation? cancel,
    String? sha256Digest,
    String? etag,
    int? expectedSize,
  }) async => throw StateError('Raw catalog must not use a file download');
}

void main() {
  test(
    'catalog stores only compact display fields, refreshes conditionally and persists language preferences',
    () async {
      final temp = await Directory.systemTemp.createTemp('nsusb-catalog-');
      try {
        final downloader = CatalogFixtureDownloader();
        final store = CatalogStore(temp, downloader: downloader);
        await store.refresh('CN.zh');
        await store.refresh('CN.zh');
        expect((await store.load('CN.zh')).titles.length, 1);
        expect(downloader.calls, 2);
        await for (final item in temp.list(recursive: true)) {
          expect(item, isA<File>());
          expect(
            await File(item.path).readAsString(),
            isNot(contains('NEVER-PERSIST')),
          );
        }
        final preferences = Preferences(File('${temp.path}/preferences.json'))
          ..region = 'HK.zh'
          ..englishFallback = false
          ..folders = ['/synthetic'];
        await preferences.save();
        final restored = Preferences(preferences.file);
        await restored.load();
        expect(restored.region, 'HK.zh');
        expect(restored.englishFallback, isFalse);
        expect(restored.folders, ['/synthetic']);
      } finally {
        await temp.delete(recursive: true);
      }
    },
  );
  test(
    'official provider selects normal Hekate and exact fusee, rejects foreign URLs',
    () {
      Map<String, dynamic> asset(
        String name, {
        String repo = 'CTCaer/hekate',
      }) => {
        'name': name,
        'size': 90000,
        'browser_download_url':
            'https://github.com/$repo/releases/download/v1/$name',
        'digest': 'sha256:${'a' * 64}',
      };
      final releases = [
        {
          'tag_name': 'v1',
          'assets': [
            asset('hekate_ctcaer_6.4.0.bin'),
            asset('hekate_ctcaer_6.4.0_ram8GB.bin'),
            asset('hekate.zip'),
            asset('hekate_ctcaer_6.3.0.bin', repo: 'someone/else'),
            asset('fusee.bin', repo: 'Atmosphere-NX/Atmosphere'),
          ],
        },
      ];
      final hekate = PayloadProvider.parse(PayloadProject.hekate, releases);
      expect(hekate.length, 1);
      expect(hekate.single.name, 'hekate_ctcaer_6.4.0.bin');
      expect(hekate.single.digest, 'a' * 64);
      expect(
        PayloadProvider.parse(PayloadProject.fusee, releases).single.name,
        'fusee.bin',
      );
    },
  );
  test(
    'bounded download verifies checksum, atomic output, ETag and cleanup on cancel',
    () async {
      final temp = await Directory.systemTemp.createTemp('nsusb-download-');
      final server = await HttpServer.bind('127.0.0.1', 0);
      final slowStarted = Completer<void>();
      server.listen((request) async {
        try {
          if (request.headers.value('if-none-match') == '"fixture"') {
            request.response.statusCode = 304;
          } else if (request.uri.path == '/gzip') {
            request.response.headers.set('Content-Encoding', 'gzip');
            request.response.add(
              gzip.encode(List.generate(300, (i) => i % 256)),
            );
          } else if (request.uri.path == '/slow') {
            request.response.add(List.filled(256, 7));
            await request.response.flush();
            if (!slowStarted.isCompleted) slowStarted.complete();
            await Future<void>.delayed(const Duration(milliseconds: 150));
            request.response.add([1]);
          } else {
            request.response.headers.set('ETag', '"fixture"');
            request.response.add(List.generate(300, (i) => i % 256));
          }
          await request.response.close();
        } catch (_) {
          /* Cancelled test client. */
        }
      });
      final downloader = Downloader(allowHttp: true),
          file = File('${temp.path}/payload.bin');
      final uri = Uri.parse('http://127.0.0.1:${server.port}/payload');
      final data = List.generate(300, (i) => i % 256);
      try {
        final result = await downloader.fetch(
          uri,
          file,
          maxBytes: 300,
          expectedSize: 300,
          sha256Digest: sha256.convert(data).toString(),
        );
        expect(result.etag, '"fixture"');
        await downloader.fetch(
          uri.resolve('/gzip'),
          File('${temp.path}/gzip.bin'),
          maxBytes: 400,
          expectedSize: 300,
          sha256Digest: sha256.convert(data).toString(),
        );
        expect(await File('${temp.path}/gzip.bin').readAsBytes(), data);

        expect(await file.readAsBytes(), data);
        expect(
          (await downloader.fetch(
            uri,
            file,
            maxBytes: 300,
            etag: result.etag,
          )).status,
          304,
        );
        await expectLater(
          downloader.fetch(uri, file, maxBytes: 200),
          throwsA(isA<HttpException>()),
        );
        expect(await file.readAsBytes(), data);
        await expectLater(
          downloader.fetch(uri, file, maxBytes: 300, sha256Digest: '0' * 64),
          throwsFormatException,
        );
        expect(await file.readAsBytes(), data);
        final cancel = Cancellation();
        final future = downloader.fetch(
          uri.resolve('/slow'),
          File('${temp.path}/cancelled'),
          maxBytes: 1000,
          cancel: cancel,
        );
        // Register the expectation before cancelling the socket.
        final expectation = expectLater(
          future,
          throwsA(
            anyOf(
              isA<Cancelled>(),
              isA<HttpException>(),
              isA<SocketException>(),
            ),
          ),
        );
        await slowStarted.future;
        cancel.cancel();
        await expectation;
        expect(await File('${temp.path}/cancelled').exists(), isFalse);
        expect(await temp.list().where((e) => e is Directory).length, 0);
      } finally {
        await server.close(force: true);
        await temp.delete(recursive: true);
      }
    },
  );
}
