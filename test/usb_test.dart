import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:ns_usbloader/core/files.dart';
import 'package:ns_usbloader/core/library.dart';
import 'package:ns_usbloader/usb/protocol.dart';
import 'package:ns_usbloader/usb/rcm.dart';

class FakeUsb implements UsbTransport {
  final List<Uint8List> incoming;
  final sent = <Uint8List>[];
  int triggers = 0;
  FakeUsb(this.incoming);
  @override
  Future<Uint8List> read(int maxLength) async => incoming.removeAt(0);
  @override
  Future<void> write(Uint8List data) async {
    sent.add(Uint8List.fromList(data));
  }

  @override
  Future<int> trigger() async {
    triggers++;
    return -7;
  }

  @override
  Future<void> close() async {}
}

Uint8List command(int id) =>
    (ByteData(12)
          ..setUint32(0, 0x30435554, Endian.little)
          ..setUint32(8, id, Endian.little))
        .buffer
        .asUint8List();
void main() {
  test(
    'RCM framing, intermezzo, spray, payload continuation and odd packet count',
    () async {
      final data = Uint8List.fromList(List.generate(32000, (i) => i % 251));
      final frame = buildRcmPayload(data);
      expect(frame.sublist(0, 3), [0x98, 0x02, 0x03]);
      expect(frame.sublist(680, 684), [0x5c, 0, 0x9f, 0xe5]);
      expect(frame.sublist(4328, 20712), data.sublist(0, 16384));
      expect(frame.sublist(20712, 20716), [0, 0, 1, 0x40]);
      expect(
        frame.sublist(29352, 29352 + data.length - 16384),
        data.sublist(16384),
      );
      expect(frame.length % 4096, 0);
      expect(frame.length ~/ 4096 % 2, 1);
      final usb = FakeUsb([Uint8List(16)]);
      expect(
        await injectRcm(usb, data, Cancellation()),
        contains('Boot is not verified'),
      );
      expect(usb.sent.every((packet) => packet.length == 4096), isTrue);
      expect(usb.triggers, 1);
      expect(() => buildRcmPayload(Uint8List(1)), throwsArgumentError);
    },
  );
  test('RCM cancellation and invalid device reply do not trigger', () async {
    final usb = FakeUsb([Uint8List(15)]);
    await expectLater(
      injectRcm(usb, Uint8List(16384), Cancellation()),
      throwsFormatException,
    );
    expect(usb.sent, isEmpty);
    expect(usb.triggers, 0);
    await expectLater(
      injectRcm(usb, Uint8List(16384), Cancellation()..cancel()),
      throwsA(isA<Cancelled>()),
    );
  });
  test(
    'Awoo range transfer from split source preserves exact framing and bytes',
    () async {
      final temp = await Directory.systemTemp.createTemp('nsusb-awoo-');
      try {
        final directory = Directory('${temp.path}/Game.nsp');
        await directory.create();
        await File('${directory.path}/00').writeAsBytes([0, 1, 2, 3]);
        await File('${directory.path}/01').writeAsBytes([4, 5, 6, 7]);
        final entry = manifest([
          Package(await FileSource.open(directory.path)),
        ]).single;
        final range =
            (ByteData(16)
                  ..setUint64(0, 5, Endian.little)
                  ..setUint64(8, 2, Endian.little))
                .buffer
                .asUint8List();
        final usb = FakeUsb([
          command(1),
          range,
          Uint8List.fromList(utf8.encode(entry.name)),
          command(0),
        ]);
        var progress = 0;
        final result = await AwooUsb(
          usb,
          Cancellation(),
          onProgress: (a, b) => progress = a,
        ).run([entry]);
        expect(result, contains('installation not verified'));
        expect(ascii.decode(usb.sent[0]), 'TUL0');
        expect(utf8.decode(usb.sent[3]), '${entry.name}\n');
        expect(
          ByteData.sublistView(usb.sent[5]).getUint64(0, Endian.little),
          5,
        );
        expect(usb.sent.skip(7).expand((packet) => packet).toList(), [
          2,
          3,
          4,
          5,
          6,
        ]);
        expect(progress, 5);
        final invalid = FakeUsb([
          command(1),
          (ByteData(16)..setUint64(0, 99, Endian.little)).buffer.asUint8List(),
          Uint8List.fromList(utf8.encode(entry.name)),
        ]);
        await expectLater(
          AwooUsb(invalid, Cancellation()).run([entry]),
          throwsRangeError,
        );
        expect(invalid.sent.length, 4);
        final unknown = FakeUsb([
          command(1),
          range,
          Uint8List.fromList(utf8.encode('../secret')),
        ]);
        await expectLater(
          AwooUsb(unknown, Cancellation()).run([entry]),
          throwsFormatException,
        );
      } finally {
        await temp.delete(recursive: true);
      }
    },
  );
}
