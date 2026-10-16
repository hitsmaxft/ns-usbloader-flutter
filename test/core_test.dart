import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:ns_usbloader/core/files.dart';
import 'package:ns_usbloader/core/library.dart';
import 'package:ns_usbloader/services/catalog.dart';

void main() {
  late Directory temp;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('nsusb-test-');
  });
  tearDown(() async {
    await temp.delete(recursive: true);
  });
  Future<File> fixture(String name, List<int> data) async {
    final file = File(p.join(temp.path, name));
    await file.parent.create(recursive: true);
    await file.writeAsBytes(data);
    return file;
  }

  test(
    'random access spans split segments; exact seek and EOF bounds',
    () async {
      await fixture('parts.nsp/00', [0, 1, 2, 3]);
      await fixture('parts.nsp/01', [4, 5, 6, 7]);
      await fixture('parts.nsp/02', [8, 9]);
      final source = await FileSource.open(p.join(temp.path, 'parts.nsp'));
      expect(await source.bytes(4, 4), [4, 5, 6, 7]);
      expect(await source.bytes(3, 6), [3, 4, 5, 6, 7, 8]);
      expect(await source.bytes(10, 0), isEmpty);
      expect(() => source.bounds(9, 2), throwsRangeError);
      expect(() => source.bounds(-1, 1), throwsRangeError);
    },
  );
  test('reject missing, unequal, empty and symlink split parts', () async {
    await fixture('gap.nsp/00', [1, 2]);
    await fixture('gap.nsp/02', [3]);
    await expectLater(
      FileSource.open(p.join(temp.path, 'gap.nsp')),
      throwsFormatException,
    );
    await fixture('unequal.nsp/00', [1]);
    await fixture('unequal.nsp/01', [2, 3]);
    await expectLater(
      FileSource.open(p.join(temp.path, 'unequal.nsp')),
      throwsFormatException,
    );
    await fixture('empty.nsp', []);
    await expectLater(
      FileSource.open(p.join(temp.path, 'empty.nsp')),
      throwsFormatException,
    );
    if (!Platform.isWindows) {
      await Directory(p.join(temp.path, 'link.nsp')).create();
      await Link(
        p.join(temp.path, 'link.nsp/00'),
      ).create(p.join(temp.path, 'unequal.nsp/00'));
      await expectLater(
        FileSource.open(p.join(temp.path, 'link.nsp')),
        throwsFormatException,
      );
    }
  });
  test('split and merge preserve exact bytes and existing outputs', () async {
    final bytes = List.generate(1031, (i) => i % 251);
    final file = await fixture('source.xci', bytes);
    final source = await FileSource.open(file.path),
        parts = p.join(temp.path, 'parts.nsp'),
        merged = p.join(temp.path, 'merged.xci');
    await splitFile(source, parts, chunkSize: 127);
    await mergeFile(await FileSource.open(parts), merged);
    expect(await File(merged).readAsBytes(), bytes);
    await expectLater(
      mergeFile(source, merged),
      throwsA(isA<FileSystemException>()),
    );
    final cancellation = Cancellation()..cancel();
    await expectLater(
      splitFile(
        source,
        p.join(temp.path, 'cancelled'),
        chunkSize: 127,
        cancel: cancellation,
      ),
      throwsA(isA<Cancelled>()),
    );
    expect(await Directory(p.join(temp.path, 'cancelled')).exists(), isFalse);
    expect(
      await temp
          .list()
          .where((e) => p.basename(e.path).startsWith('.nsusb'))
          .length,
      0,
    );
  });
  test('changed or replaced source is refused', () async {
    final file = await fixture('change.nsp', [1, 2, 3]);
    final source = await FileSource.open(file.path);
    await file.writeAsBytes([9, 8]);
    await expectLater(source.bytes(0, 3), throwsA(isA<FileSystemException>()));
  });
  test(
    'scan IDs group base, copies, updates and DLC; orphans remain visible',
    () async {
      for (final name in [
        'a/Orbit [0100000000002000][v0].nsp',
        'b/Orbit [0100000000002000][v0].xci',
        'Orbit patch [0100000000002800][v65536].nsp',
        'Orbit extras [0100000000003001].nsp',
        'Orphan [0100000000007001].nsp',
        'Orbit without ID.nsp',
        'Orbit without ID.xci',
      ]) {
        await fixture(name, [1, 2, 3]);
      }
      if (!Platform.isWindows) {
        await Link(p.join(temp.path, 'loop')).create(temp.path);
      }
      final scanner = LibraryScanner();
      final result = await scanner.scan([temp.path, temp.path]);
      expect(result.issues, isEmpty);
      expect(result.packages.length, 7);
      final groups = groupPackages(result.packages);
      expect(groups.length, 4);
      final main = groups.singleWhere((g) => g.id == '0100000000002000');
      expect(main.count(ContentKind.base), 2);
      expect(main.count(ContentKind.update), 1);
      expect(main.count(ContentKind.dlc), 1);
      expect(
        groups.singleWhere((g) => g.id == '0100000000006000').orphan,
        isTrue,
      );
      final selected = manifest(result.packages);
      expect(selected.map((e) => e.name).toSet().length, 7);
    },
  );
  test(
    'scan recognizes explicit compact filename IDs without name guessing',
    () async {
      for (final name in [
        'DaveTheDiver010097F018538000APPv0.nsp',
        'DaveTheDiver010097F018538800UPDv65536.nsp',
        'DaveTheDiver010097F018539001DLCv0.nsp',
        'Mario (0100EA80032EA000).nsp',
      ]) {
        await fixture(name, [1, 2, 3]);
      }

      final result = await LibraryScanner().scan([temp.path]);
      final dave = groupPackages(
        result.packages,
      ).singleWhere((group) => group.id == '010097F018538000');
      expect(dave.count(ContentKind.base), 1);
      expect(dave.count(ContentKind.update), 1);
      expect(dave.count(ContentKind.dlc), 1);
      expect(
        result.packages.every(
          (item) => item.evidence == IdentityEvidence.filename,
        ),
        isTrue,
      );
    },
  );
  test('manual override changes and reset invalidate scan cache', () async {
    final file = await fixture('Mystery.nsp', [1]);
    final scanner = LibraryScanner();
    var result = await scanner.scan([temp.path]);
    expect(result.packages.single.evidence, IdentityEvidence.unknown);
    result = await scanner.scan(
      [temp.path],
      overrides: {
        file.path: {'titleId': '0100000000002000', 'kind': 'base'},
      },
    );
    expect(result.packages.single.evidence, IdentityEvidence.manual);
    result = await scanner.scan([temp.path]);
    expect(result.packages.single.titleId, isNull);
  });
  test(
    'plaintext CNMT wins over filename; encrypted names are not identity',
    () async {
      final name = utf8.encode('content.cnmt\x00');
      final tableEnd = 16 + 24 + name.length;
      final bytes = Uint8List(tableEnd + 40);
      bytes.setRange(0, 4, ascii.encode('PFS0'));
      final data = ByteData.sublistView(bytes)
        ..setUint32(4, 1, Endian.little)
        ..setUint32(8, name.length, Endian.little)
        ..setUint64(24, 40, Endian.little);
      bytes.setRange(40, tableEnd, name);
      data
        ..setUint64(tableEnd, 0x0100000000002800, Endian.little)
        ..setUint32(tableEnd + 8, 65536, Endian.little)
        ..setUint8(tableEnd + 12, 0x81)
        ..setUint16(tableEnd + 14, 8, Endian.little)
        ..setUint64(tableEnd + 32, 0x0100000000002000, Endian.little);
      await fixture('Wrong [0100000000008000].nsp', bytes);
      final result = await LibraryScanner().scan([temp.path]);
      final item = result.packages.single;
      expect(item.titleId, '0100000000002800');
      expect(item.evidence, IdentityEvidence.package);
      expect(item.version, '65536');
      expect(item.groupId, '0100000000002000');
      expect(item.kind, ContentKind.update);
    },
  );
  test(
    'metadata allowlist uses value ID, drops secrets and suggests without grouping',
    () {
      final compact = compactCatalog({
        'nsuid': {
          'id': '0100000000002000',
          'name': 'Orbit Garden',
          'publisher': 'Synthetic Studio',
          'key': 'DO-NOT-PERSIST',
          'rightsId': 'DO-NOT-PERSIST',
          'iconUrl': 'https://example.com/icon.png',
        },
      });
      final serialized = jsonEncode(
        compact.map((k, v) => MapEntry(k, v.toJson())),
      );
      expect(serialized, isNot(contains('DO-NOT-PERSIST')));
      expect(compact.keys, ['0100000000002000']);
      expect(Catalog(compact).suggestions('Orbit').single.name, 'Orbit Garden');
    },
  );
}
