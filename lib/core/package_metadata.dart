// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';
import 'dart:typed_data';
import 'files.dart';

class ReadableMetadata {
  final String titleId;
  final int version, type;
  final String? applicationId;
  ReadableMetadata(this.titleId, this.version, this.type, this.applicationId);
}

/// Bounded PFS0 reader for explicitly plaintext .cnmt entries only.
/// Ordinary encrypted .cnmt.nca entries are not decrypted or guessed.
Future<ReadableMetadata?> readPlaintextMetadata(FileSource source) async {
  if (source.length < 16) return null;
  final header = await source.bytes(0, 16);
  if (ascii.decode(header.sublist(0, 4), allowInvalid: true) != 'PFS0') {
    return null;
  }
  final h = ByteData.sublistView(header);
  final count = h.getUint32(4, Endian.little),
      strings = h.getUint32(8, Endian.little);
  if (count > 1024 || strings > 65536) return null;
  final tableLength = count * 24 + strings, dataStart = 16 + tableLength;
  if (dataStart > source.length) return null;
  final table = await source.bytes(16, tableLength);
  final entries = ByteData.sublistView(table);
  final found = <ReadableMetadata>[];
  for (var i = 0; i < count; i++) {
    final offset = entries.getUint64(i * 24, Endian.little);
    final size = entries.getUint64(i * 24 + 8, Endian.little);
    final nameOffset = entries.getUint32(i * 24 + 16, Endian.little);
    if (nameOffset >= strings ||
        offset < 0 ||
        size < 0 ||
        offset > source.length - dataStart ||
        size > source.length - dataStart - offset) {
      return null;
    }
    final start = count * 24 + nameOffset;
    final end = table.indexOf(0, start);
    if (end < start) return null;
    final name = utf8.decode(table.sublist(start, end), allowMalformed: true);
    if (!name.endsWith('.cnmt') || size < 32 || size > 65536) continue;
    final content = ByteData.sublistView(
      await source.bytes(dataStart + offset, size),
    );
    final type = content.getUint8(12);
    if (![0x80, 0x81, 0x82].contains(type)) continue;
    String idAt(int at) => content
        .getUint64(at, Endian.little)
        .toUnsigned(64)
        .toRadixString(16)
        .padLeft(16, '0')
        .toUpperCase();
    final extended = content.getUint16(14, Endian.little);
    if (32 + extended > size) return null;
    final appId = type != 0x80 && extended >= 8 ? idAt(32) : null;
    found.add(
      ReadableMetadata(
        idAt(0),
        content.getUint32(8, Endian.little),
        type,
        appId,
      ),
    );
  }
  // A multi-title package requires an explicit choice instead of picking a title.
  return found.length == 1 ? found.single : null;
}
