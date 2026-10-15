import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:ns_usbloader/core/files.dart';
import 'package:ns_usbloader/core/library.dart';
import 'package:ns_usbloader/services/network.dart';

void main() {
  late Directory temp;
  late NetworkTransfer transfer;
  late Cancellation cancel;
  late HttpClient client;
  late List<ManifestEntry> entries;
  final bytes = List.generate(300, (i) => i % 256);
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('nsusb-http-');
    for (final folder in ['a', 'b']) {
      await Directory('${temp.path}/$folder').create();
      await File('${temp.path}/$folder/Same.nsp').writeAsBytes(bytes);
    }
    await Directory('${temp.path}/split.nsp').create();
    await File('${temp.path}/split.nsp/00').writeAsBytes(bytes.sublist(0, 150));
    await File('${temp.path}/split.nsp/01').writeAsBytes(bytes.sublist(150));
    entries = manifest((await LibraryScanner().scan([temp.path])).packages);
    cancel = Cancellation();
    transfer = NetworkTransfer(entries, cancel);
    await transfer.serve('127.0.0.1');
    client = HttpClient();
  });
  tearDown(() async {
    client.close(force: true);
    await transfer.close();
    await temp.delete(recursive: true);
  });
  Future<(int, List<int>, HttpHeaders)> request(
    ManifestEntry entry, {
    String method = 'GET',
    String? range,
    String? path,
  }) async {
    final req = await client.openUrl(
      method,
      Uri.parse(
        'http://127.0.0.1:${transfer.port}${path ?? '/${entry.id}/${Uri.encodeComponent(entry.name)}'}',
      ),
    );
    if (range != null) req.headers.set('Range', range);
    final response = await req.close();
    final data = await response.fold<List<int>>([], (a, b) => a..addAll(b));
    return (response.statusCode, data, response.headers);
  }

  test(
    'normal, suffix, open range, full GET and HEAD across split files',
    () async {
      for (final entry in entries) {
        final normal = await request(entry, range: 'bytes=10-19');
        expect(normal.$1, 206);
        expect(normal.$2, bytes.sublist(10, 20));
        final suffix = await request(entry, range: 'bytes=-100');
        expect(suffix.$2, bytes.sublist(200));
        expect(suffix.$3.value('content-range'), 'bytes 200-299/300');
        expect(
          (await request(entry, range: 'bytes=140-160')).$2,
          bytes.sublist(140, 161),
        );
        expect(
          (await request(entry, range: 'bytes=290-')).$2,
          bytes.sublist(290),
        );
        expect((await request(entry, method: 'HEAD')).$2, isEmpty);
        final all = await request(entry);
        expect(all.$1, 200);
        expect(all.$2, bytes);
      }
      expect(transfer.served, 900);
      expect(transfer.allBytesServed, isTrue);
      await request(entries.first);
      expect(transfer.served, 900);
    },
  );
  test(
    'invalid ranges, allowlist, traversal and methods are rejected',
    () async {
      for (final range in [
        'bytes=-0',
        'bytes=300-',
        'bytes=20-10',
        'bytes=1-2,4-5',
        'nonsense',
      ]) {
        expect((await request(entries.first, range: range)).$1, 416);
      }
      expect((await request(entries.first, path: '/etc/passwd')).$1, 404);
      expect(
        (await request(
          entries.first,
          path: '/${entries.first.id}/wrong.nsp',
        )).$1,
        404,
      );
      expect((await request(entries.first, method: 'POST')).$1, 405);
      expect(transfer.served, 0);
    },
  );
  test(
    'bind before advertisement, unique URLs and big endian length',
    () async {
      final fakeConsole = await ServerSocket.bind('127.0.0.1', 0);
      final message = Completer<List<int>>();
      final sub = fakeConsole.listen((socket) async {
        message.complete(
          await socket.fold<List<int>>([], (a, b) => a..addAll(b)),
        );
      });
      try {
        await transfer.advertise(
          '127.0.0.1',
          '127.0.0.1',
          consolePort: fakeConsole.port,
        );
        final data = Uint8List.fromList(
          await message.future.timeout(const Duration(seconds: 5)),
        );
        expect(
          ByteData.sublistView(data).getUint32(0, Endian.big),
          data.length - 4,
        );
        final urls = utf8.decode(data.sublist(4)).trim().split('\n');
        expect(urls.toSet().length, 3);
        expect(urls.first, startsWith('127.0.0.1:${transfer.port}/'));
        expect((await request(entries.first)).$1, 200);
      } finally {
        await sub.cancel();
        await fakeConsole.close();
      }
    },
  );
  test('cancellation closes listener without inventing completion', () async {
    await request(entries.first, range: 'bytes=0-9');
    final port = transfer.port;
    cancel.cancel();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(transfer.allBytesServed, isFalse);
    expect(transfer.served, 10);
    await expectLater(
      Socket.connect('127.0.0.1', port),
      throwsA(isA<SocketException>()),
    );
  });
}
