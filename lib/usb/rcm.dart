// SPDX-License-Identifier: GPL-3.0-or-later
// Payload framing and intermezzo adapted from NS-USBloader, Copyright
// 2019-2020 Dmitry Isaenko, based on fusee-launcher by Katherine Temkin.
import 'dart:typed_data';
import '../core/files.dart';
import 'protocol.dart';

final _intermezzo = Uint8List.fromList([
  0x5c,
  0x00,
  0x9f,
  0xe5,
  0x5c,
  0x10,
  0x9f,
  0xe5,
  0x5c,
  0x20,
  0x9f,
  0xe5,
  0x01,
  0x20,
  0x42,
  0xe0,
  0x0e,
  0x00,
  0x00,
  0xeb,
  0x48,
  0x00,
  0x9f,
  0xe5,
  0x10,
  0xff,
  0x2f,
  0xe1,
  0x00,
  0x00,
  0xa0,
  0xe1,
  0x48,
  0x00,
  0x9f,
  0xe5,
  0x48,
  0x10,
  0x9f,
  0xe5,
  0x01,
  0x29,
  0xa0,
  0xe3,
  0x07,
  0x00,
  0x00,
  0xeb,
  0x38,
  0x00,
  0x9f,
  0xe5,
  0x01,
  0x19,
  0xa0,
  0xe3,
  0x01,
  0x00,
  0x80,
  0xe0,
  0x34,
  0x10,
  0x9f,
  0xe5,
  0x03,
  0x28,
  0xa0,
  0xe3,
  0x01,
  0x00,
  0x00,
  0xeb,
  0x20,
  0x00,
  0x9f,
  0xe5,
  0x10,
  0xff,
  0x2f,
  0xe1,
  0x04,
  0x30,
  0x91,
  0xe4,
  0x04,
  0x30,
  0x80,
  0xe4,
  0x04,
  0x20,
  0x52,
  0xe2,
  0xfb,
  0xff,
  0xff,
  0x1a,
  0x1e,
  0xff,
  0x2f,
  0xe1,
  0x00,
  0xf0,
  0x00,
  0x40,
  0x20,
  0x00,
  0x01,
  0x40,
  0x7c,
  0x00,
  0x01,
  0x40,
  0x00,
  0x00,
  0x01,
  0x40,
  0x40,
  0x0e,
  0x01,
  0x40,
  0x00,
  0x70,
  0x01,
  0x40,
]);
Uint8List buildRcmPayload(Uint8List payload) {
  if (payload.length < 16384 || payload.length > 126296) {
    throw ArgumentError('RCM payload must be 16384–126296 bytes');
  }
  var size = 4328 + payload.length + 8640;
  size += 4096 - size % 4096;
  if (size ~/ 4096 % 2 == 0) size += 4096;
  if (size > 0x30298) throw ArgumentError('RCM frame too large');
  final frame = Uint8List(size);
  frame.setRange(0, 3, [0x98, 0x02, 0x03]);
  frame.setRange(680, 804, _intermezzo);
  frame.setRange(4328, 20712, payload);
  final data = ByteData.sublistView(frame);
  for (var i = 0; i < 2160; i++) {
    data.setUint32(20712 + i * 4, 0x40010000, Endian.little);
  }
  frame.setRange(29352, 29352 + payload.length - 16384, payload, 16384);
  return frame;
}

Future<String> injectRcm(
  UsbTransport transport,
  Uint8List payload,
  Cancellation cancel,
) async {
  final frame = buildRcmPayload(payload);
  cancel.check();
  final id = await transport.read(16);
  if (id.length != 16) {
    throw const FormatException('Invalid RCM device identity response');
  }
  for (var offset = 0; offset < frame.length; offset += 4096) {
    cancel.check();
    await transport.write(Uint8List.sublistView(frame, offset, offset + 4096));
  }
  cancel.check();
  final result = await transport.trigger();
  return 'Trigger request returned status $result. Boot is not verified.';
}
