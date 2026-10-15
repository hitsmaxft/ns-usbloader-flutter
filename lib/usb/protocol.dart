// SPDX-License-Identifier: GPL-3.0-or-later
// Awoo and RCM framing adapted from NS-USBloader by Dmitry Isaenko.
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import '../core/files.dart';
import '../core/library.dart';
import '../services/network.dart';

abstract interface class UsbTransport {
  Future<Uint8List> read(int maxLength);
  Future<void> write(Uint8List data);
  Future<int> trigger();
  Future<void> close();
}

class AwooUsb {
  final UsbTransport transport;
  final Cancellation cancel;
  final void Function(int, int)? onProgress;
  AwooUsb(this.transport, this.cancel, {this.onProgress});
  Future<String> run(List<ManifestEntry> entries) async {
    if (entries.isEmpty) throw ArgumentError('Select files first');
    final files = {for (final entry in entries) entry.name: entry};
    final names = Uint8List.fromList(utf8.encode('${files.keys.join('\n')}\n'));
    if (names.length > 1024 * 1024) {
      throw ArgumentError('Transfer list too large');
    }
    final coverage = <String, Coverage>{};
    await transport.write(Uint8List.fromList(ascii.encode('TUL0')));
    await transport.write(
      (ByteData(
        4,
      )..setUint32(0, names.length, Endian.little)).buffer.asUint8List(),
    );
    await transport.write(Uint8List(8));
    await transport.write(names);
    while (true) {
      cancel.check();
      final header = await transport.read(512);
      if (header.length < 12 ||
          ascii.decode(header.sublist(0, 4), allowInvalid: true) != 'TUC0') {
        throw const FormatException('Invalid Awoo command');
      }
      final data = ByteData.sublistView(header);
      if (data.getUint32(4, Endian.little) != 0) {
        throw const FormatException('Expected Awoo request');
      }
      final command = data.getUint32(8, Endian.little);
      if (command == 0) {
        return 'Device ended session; installation not verified';
      }
      if (command != 1 && command != 2) {
        throw FormatException('Unknown Awoo command $command');
      }
      final request = await transport.read(512);
      if (request.length < 16) {
        throw const FormatException('Truncated file range');
      }
      final range = ByteData.sublistView(request);
      final size = range.getUint64(0, Endian.little),
          offset = range.getUint64(8, Endian.little);
      final name = utf8.decode(await transport.read(512));
      final entry = files[name];
      if (entry == null) {
        throw const FormatException('File is not in selected manifest');
      }
      entry.source.bounds(offset, size);
      final reply = ByteData(12)
        ..setUint32(0, 0x30435554, Endian.little)
        ..setUint32(4, 1, Endian.little)
        ..setUint32(8, 1, Endian.little);
      await transport.write(reply.buffer.asUint8List());
      await transport.write(
        (ByteData(8)..setUint64(0, size, Endian.little)).buffer.asUint8List(),
      );
      await transport.write(Uint8List(12));
      var position = offset;
      while (position < offset + size) {
        cancel.check();
        // Preserve USB transfer block boundaries across split-file segments.
        final bytes = await entry.source.bytes(
          position,
          min(0x800000, offset + size - position),
        );
        cancel.check();
        await transport.write(bytes);
        coverage
            .putIfAbsent(entry.id, () => Coverage())
            .add(position, position + bytes.length);
        position += bytes.length;
        onProgress?.call(
          coverage.values.fold(0, (s, c) => s + c.bytes),
          entries.fold(0, (s, e) => s + e.source.length),
        );
      }
    }
  }
}
