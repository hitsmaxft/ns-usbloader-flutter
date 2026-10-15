// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:path/path.dart' as p;

class Cancelled implements Exception {
  @override
  String toString() => 'Cancelled';
}

class Cancellation {
  bool cancelled = false;
  final List<void Function()> _listeners = [];
  void cancel() {
    if (cancelled) return;
    cancelled = true;
    for (final listener in List.of(_listeners)) {
      listener();
    }
  }

  void check() {
    if (cancelled) throw Cancelled();
  }

  void Function() listen(void Function() callback) {
    if (cancelled) {
      callback();
    } else {
      _listeners.add(callback);
    }
    return () => _listeners.remove(callback);
  }
}

/// Immutable segment snapshot. Reads verify size and mtime before opening.
class FileSource {
  final String path;
  final List<String> segments;
  final List<int> sizes;
  final List<int> modified;
  FileSource(this.path, this.segments, this.sizes, this.modified);
  int get length => sizes.fold(0, (a, b) => a + b);
  String get name => p.basename(path);
  static Future<FileSource> open(String path) async {
    final type = await FileSystemEntity.type(path, followLinks: false);
    final List<String> segments;
    if (type == FileSystemEntityType.directory) {
      segments = [];
      await for (final entry in Directory(path).list(followLinks: false)) {
        if (entry is! File ||
            !RegExp(r'^\d{2}$').hasMatch(p.basename(entry.path))) {
          throw FormatException(
            'Unexpected entry in split package: ${entry.path}',
          );
        }
        segments.add(entry.path);
      }
      segments.sort();
      if (segments.isEmpty) throw const FormatException('Empty split package');
      for (var i = 0; i < segments.length; i++) {
        if (p.basename(segments[i]) != i.toString().padLeft(2, '0')) {
          throw const FormatException('Missing split segment');
        }
      }
    } else if (type == FileSystemEntityType.file) {
      segments = [path];
    } else {
      throw const FormatException('Expected a regular file or split directory');
    }
    final stats = await Future.wait(segments.map((s) => File(s).stat()));
    final sizes = stats.map((s) => s.size).toList();
    if (sizes.any((s) => s == 0)) {
      throw const FormatException('Empty package segment');
    }
    if (segments.length > 1 &&
        (sizes.take(sizes.length - 1).any((s) => s != sizes.first) ||
            sizes.last > sizes.first)) {
      throw const FormatException('Inconsistent split segment sizes');
    }
    return FileSource(
      p.normalize(p.absolute(path)),
      segments,
      sizes,
      stats.map((s) => s.modified.microsecondsSinceEpoch).toList(),
    );
  }

  void bounds(int offset, int count) {
    if (offset < 0 || count < 0 || offset > length || count > length - offset) {
      throw RangeError('Range $offset + $count exceeds $length');
    }
  }

  Stream<List<int>> read(int offset, int count, {Cancellation? cancel}) async* {
    bounds(offset, count);
    var base = 0;
    for (var i = 0; i < segments.length && count > 0; i++) {
      if (offset >= base + sizes[i]) {
        base += sizes[i];
        continue;
      }
      cancel?.check();
      if (await FileSystemEntity.type(segments[i], followLinks: false) !=
          FileSystemEntityType.file) {
        throw FileSystemException('Segment replaced', segments[i]);
      }
      final stat = await File(segments[i]).stat();
      if (stat.size != sizes[i] ||
          stat.modified.microsecondsSinceEpoch != modified[i]) {
        throw FileSystemException('File changed since selection', segments[i]);
      }
      final handle = await File(segments[i]).open();
      try {
        final local = offset - base;
        await handle.setPosition(local);
        var left = min(count, sizes[i] - local);
        while (left > 0) {
          cancel?.check();
          final bytes = await handle.read(min(left, 256 * 1024));
          if (bytes.isEmpty) {
            throw const FileSystemException('Unexpected end of file');
          }
          left -= bytes.length;
          count -= bytes.length;
          offset += bytes.length;
          yield bytes;
        }
      } finally {
        await handle.close();
      }
      base += sizes[i];
    }
  }

  Future<Uint8List> bytes(int offset, int count) async {
    final out = BytesBuilder(copy: false);
    await for (final chunk in read(offset, count)) {
      out.add(chunk);
    }
    return out.takeBytes();
  }
}

/// Staging siblings are renamed only on success. Existing outputs are refused.
Future<void> splitFile(
  FileSource source,
  String output, {
  int chunkSize = 0xffff0000,
  Cancellation? cancel,
}) async {
  if (chunkSize <= 0 || (source.length / chunkSize).ceil() > 100) {
    throw ArgumentError('Choose a size producing 1–100 parts');
  }
  if (await FileSystemEntity.type(output) != FileSystemEntityType.notFound) {
    throw const FileSystemException('Output already exists');
  }
  final staging = await Directory(
    p.dirname(output),
  ).createTemp('.nsusb-split-');
  try {
    for (
      var offset = 0, part = 0;
      offset < source.length;
      offset += chunkSize, part++
    ) {
      cancel?.check();
      final sink = File(
        p.join(staging.path, part.toString().padLeft(2, '0')),
      ).openWrite();
      try {
        await sink.addStream(
          source.read(
            offset,
            min(chunkSize, source.length - offset),
            cancel: cancel,
          ),
        );
      } finally {
        await sink.close();
      }
    }
    cancel?.check();
    if (await FileSystemEntity.type(output) != FileSystemEntityType.notFound) {
      throw const FileSystemException('Output already exists');
    }
    await staging.rename(output);
  } catch (_) {
    if (await staging.exists()) await staging.delete(recursive: true);
    rethrow;
  }
}

Future<void> mergeFile(
  FileSource source,
  String output, {
  Cancellation? cancel,
}) async {
  if (await FileSystemEntity.type(output) != FileSystemEntityType.notFound) {
    throw const FileSystemException('Output already exists');
  }
  final staging = await Directory(
    p.dirname(output),
  ).createTemp('.nsusb-merge-');
  try {
    final file = File(p.join(staging.path, 'merged'));
    final sink = file.openWrite();
    try {
      await sink.addStream(source.read(0, source.length, cancel: cancel));
    } finally {
      await sink.close();
    }
    cancel?.check();
    if (await FileSystemEntity.type(output) != FileSystemEntityType.notFound) {
      throw const FileSystemException('Output already exists');
    }
    await file.rename(output);
  } finally {
    await staging.delete(recursive: true);
  }
}
