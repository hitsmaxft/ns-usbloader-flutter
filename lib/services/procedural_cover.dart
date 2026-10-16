// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';

/// Small deterministic original artwork for library records without a cached
/// title cover. It is generated in memory and never represents game artwork.
class ProceduralCover {
  static const width = 128;
  static const height = 128;
  static const _signature = <int>[137, 80, 78, 71, 13, 10, 26, 10];

  static Uint8List png(String identity) {
    final seed = sha256.convert(utf8.encode(identity)).bytes;
    final raw = Uint8List(height * (1 + width * 4));
    var offset = 0;
    for (var y = 0; y < height; y++) {
      raw[offset++] = 0; // PNG's no-filter byte for this row.
      for (var x = 0; x < width; x++) {
        final diagonal = (x * 5 + y * 3 + seed[6]) % 29;
        var red = _mix(seed[0], seed[3], y, height);
        var green = _mix(seed[1], seed[4], x, width);
        var blue = _mix(seed[2], seed[5], x + y, width * 2);
        if (diagonal < 4) {
          red = _brighten(red, 18);
          green = _brighten(green, 18);
          blue = _brighten(blue, 18);
        }
        for (var circle = 0; circle < 3; circle++) {
          final centerX = 18 + seed[7 + circle] % 92;
          final centerY = 18 + seed[10 + circle] % 92;
          final radius = 20 + seed[13 + circle] % 38;
          final dx = x - centerX;
          final dy = y - centerY;
          if (dx * dx + dy * dy < radius * radius) {
            red = _brighten(red, 13);
            green = _brighten(green, 13);
            blue = _brighten(blue, 13);
          }
        }
        // Eight levels per channel keep the abstract artwork legible while
        // making the PNG economical for a console-side cache.
        raw[offset++] = _quantize(red);
        raw[offset++] = _quantize(green);
        raw[offset++] = _quantize(blue);
        raw[offset++] = 255;
      }
    }
    final compressed = ZLibEncoder(level: 6).convert(raw);
    final output = BytesBuilder(copy: false)..add(_signature);
    output.add(
      _chunk('IHDR', [0, 0, 0, width, 0, 0, 0, height, 8, 6, 0, 0, 0]),
    );
    output.add(_chunk('IDAT', compressed));
    output.add(_chunk('IEND', const []));
    return output.toBytes();
  }

  static int _mix(int first, int second, int value, int maximum) =>
      (first * (maximum - value) + second * value) ~/ maximum;
  static int _brighten(int value, int amount) =>
      value + amount > 255 ? 255 : value + amount;
  static int _quantize(int value) => value & 0xe0;

  static Uint8List _chunk(String type, List<int> data) {
    final name = ascii.encode(type);
    final bytes = BytesBuilder(copy: false)
      ..add(_u32(data.length))
      ..add(name)
      ..add(data);
    final payload = bytes.toBytes();
    return Uint8List.fromList([
      ...payload,
      ..._u32(_crc32([...name, ...data])),
    ]);
  }

  static List<int> _u32(int value) => [
    (value >>> 24) & 0xff,
    (value >>> 16) & 0xff,
    (value >>> 8) & 0xff,
    value & 0xff,
  ];

  static int _crc32(List<int> bytes) {
    var value = 0xffffffff;
    for (final byte in bytes) {
      value ^= byte;
      for (var bit = 0; bit < 8; bit++) {
        value = (value & 1) == 0 ? value >>> 1 : (value >>> 1) ^ 0xedb88320;
      }
    }
    return (value ^ 0xffffffff) & 0xffffffff;
  }
}
