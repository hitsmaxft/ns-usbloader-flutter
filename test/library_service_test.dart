import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:ns_usbloader/services/library_api.dart';
import 'package:ns_usbloader/services/library_service.dart';

void main() {
  late Directory temp;
  late Directory root;
  late Directory data;
  late LibraryService library;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('nsusb-library-');
    root = await Directory(p.join(temp.path, 'games')).create();
    data = await Directory(p.join(temp.path, 'data')).create();
    await File(
      p.join(root.path, 'Orbit [0100000000002000][v0].nsp'),
    ).writeAsBytes([1, 2, 3]);
    await File(
      p.join(root.path, 'Orbit update [0100000000002800][v65536].nsz'),
    ).writeAsBytes([4, 5, 6]);
    await File(
      p.join(root.path, 'Orbit DLC [0100000000003001].xci'),
    ).writeAsBytes([7, 8, 9]);
    await File(
      p.join(root.path, 'Orphan [0100000000007001].xcz'),
    ).writeAsBytes([10]);
    library = await LibraryService.open(data);
  });

  tearDown(() async {
    await library.close();
    await temp.delete(recursive: true);
  });

  test(
    'persists sources, package relationships and unavailable mounts',
    () async {
      final source = await library.addSource(root.path);
      expect(source.published, isTrue);
      expect(await library.scan(), isEmpty);
      expect(library.packages, hasLength(4));
      final main = library.packages
          .where((item) => item.package.groupId == '0100000000002000')
          .toList();
      expect(
        main.map((item) => item.package.kind.name),
        containsAll(['base', 'update', 'dlc']),
      );
      expect(
        library.packages
            .singleWhere((item) => item.package.groupId == '0100000000006000')
            .available,
        isTrue,
      );
      final stableServerId = library.serverId;
      final stableRevision = library.revision;
      expect(await library.scan(), isEmpty);
      expect(
        library.revision,
        stableRevision,
        reason: 'An unchanged indexed source does not enumerate or revise',
      );
      await File(
        p.join(root.path, 'Orbit bonus [0100000000003002].nsp'),
      ).writeAsBytes([11, 12]);
      expect(await library.scan(), isEmpty);
      expect(library.packages, hasLength(5));
      expect(library.revision, isNot(stableRevision));
      final updatedRevision = library.revision;
      await library.close();
      library = await LibraryService.open(data);
      expect(library.serverId, stableServerId);
      expect(library.revision, updatedRevision);
      expect(library.sources.single.path, root.path);
      expect(library.packages, hasLength(5));
      await root.rename(p.join(temp.path, 'games-offline'));
      final issues = await library.scan();
      expect(issues.single, contains('source unavailable'));
      expect(library.packages, hasLength(5));
      expect(library.packages.every((item) => !item.available), isTrue);
    },
  );

  test(
    'manual override survives store restart and invalidates persistent scan cache',
    () async {
      final mystery = File(p.join(root.path, 'Mystery.nsp'));
      await mystery.writeAsBytes([42]);
      await library.addSource(root.path);
      await library.scan();
      final item = library.packages.singleWhere(
        (item) => item.package.source.path == mystery.path,
      );
      expect(item.package.titleId, isNull);
      library.setOverride(item.package, {
        'titleId': '0100000000005000',
        'kind': 'base',
      });
      await library.scan();
      expect(
        library.packages
            .singleWhere((item) => item.package.source.path == mystery.path)
            .package
            .titleId,
        '0100000000005000',
      );
      await library.close();
      library = await LibraryService.open(data);
      await library.scan();
      expect(
        library.packages
            .singleWhere((item) => item.package.source.path == mystery.path)
            .package
            .titleId,
        '0100000000005000',
      );
    },
  );

  test('read-only gallery API pages exact packages and ranges', () async {
    await library.addSource(root.path);
    await library.scan();
    final server = LibraryApiServer(
      library,
      const LibraryServerConfig(
        bindAddress: '127.0.0.1',
        port: 0,
        name: 'Synthetic library',
        bearerToken: 'test-token',
      ),
    );
    await server.start();
    final client = HttpClient();
    Future<(HttpClientResponse, List<int>)> get(
      String path, {
      String? token,
      String? range,
    }) async {
      final request = await client.getUrl(
        Uri.parse('http://127.0.0.1:${server.port}$path'),
      );
      if (token != null) {
        request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      }
      if (range != null) request.headers.set(HttpHeaders.rangeHeader, range);
      final response = await request.close();
      return (
        response,
        await response.fold<List<int>>([], (all, bytes) => all..addAll(bytes)),
      );
    }

    try {
      expect(
        (await get('/api/awoo/v1/info')).$1.statusCode,
        HttpStatus.unauthorized,
      );
      expect((await get('/healthz')).$1.statusCode, HttpStatus.ok);
      final info = await get('/api/awoo/v1/info', token: 'test-token');
      final infoJson = jsonDecode(utf8.decode(info.$2)) as Map<String, dynamic>;
      expect(infoJson['name'], 'Synthetic library');
      final page = await get('/api/awoo/v1/games?limit=1', token: 'test-token');
      final pageJson = jsonDecode(utf8.decode(page.$2)) as Map<String, dynamic>;
      expect((pageJson['games'] as List), hasLength(1));
      final gameId = (pageJson['games'] as List).single['id'] as String;
      final revision = pageJson['libraryRevision'] as String;
      final detail = await get(
        '/api/awoo/v1/games/$gameId?revision=$revision',
        token: 'test-token',
      );
      final detailJson =
          jsonDecode(utf8.decode(detail.$2)) as Map<String, dynamic>;
      final packages = detailJson['packages'] as List;
      expect(packages, hasLength(3));
      final url = packages.first['downloadUrl'] as String;
      final range = await get(url, token: 'test-token', range: 'bytes=1-2');
      expect(range.$1.statusCode, HttpStatus.partialContent);
      expect(range.$2, [2, 3]);
      final stale = await get(
        '/api/awoo/v1/games/$gameId?revision=r0',
        token: 'test-token',
      );
      expect(stale.$1.statusCode, HttpStatus.conflict);
      expect(
        (await get(
          '/api/awoo/v1/games?limit=0',
          token: 'test-token',
        )).$1.statusCode,
        HttpStatus.badRequest,
      );
      await File(
        p.join(root.path, 'Orbit [0100000000002000][v0].nsp'),
      ).writeAsBytes([99]);
      expect(
        (await get(url, token: 'test-token')).$1.statusCode,
        HttpStatus.conflict,
      );
      final traversal = await get(
        '/api/awoo/v1/packages/../../etc/passwd',
        token: 'test-token',
      );
      expect(traversal.$1.statusCode, HttpStatus.notFound);
    } finally {
      client.close(force: true);
      await server.close();
    }
  });
}
