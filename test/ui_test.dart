import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ns_usbloader/core/files.dart';
import 'package:ns_usbloader/core/library.dart';
import 'package:ns_usbloader/services/catalog.dart';
import 'package:ns_usbloader/ui/app.dart';
import 'package:ns_usbloader/ui/controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  late AppController controller;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('nsusb-ui-');
    controller = AppController(temp);
    final titles = [
      'Orbit Garden',
      'Velvet Horizon',
      'Paper Voyager',
      'Lumen Valley',
      'Midnight Circuit',
      'Coral Atlas',
      'Ember Station',
      'Solstice',
    ];
    for (var i = 0; i < titles.length; i++) {
      final id = (0x0100000000002000 + i * 0x2000)
          .toRadixString(16)
          .toUpperCase()
          .padLeft(16, '0');
      final source = FileSource('/Synthetic/${titles[i]} [$id].nsp', [], [
        1024 * 1024 * 1024 * (i + 1),
      ], []);
      controller.packages.add(
        Package(source, titleId: id, evidence: IdentityEvidence.filename),
      );
      controller.catalog.titles[id] = TitleMetadata(
        id,
        titles[i],
        'Original fixture studio',
        null,
      );
    }
    for (final pair in [
      ('0100000000002800', ContentKind.update),
      ('0100000000003001', ContentKind.dlc),
    ]) {
      controller.packages.add(
        Package(
          FileSource('/Synthetic/Orbit Garden [${pair.$1}][v65536].nsp', [], [
            300 * 1024 * 1024,
          ], []),
          titleId: pair.$1,
          evidence: IdentityEvidence.filename,
        ),
      );
    }
  });
  tearDown(() async {
    controller.dispose();
    await temp.delete(recursive: true);
  });
  Future<void> fonts() async {
    final root = Platform.environment['FLUTTER_ROOT'];
    if (root == null) return;
    final icons = FontLoader('MaterialIcons')
      ..addFont(
        File(
          '$root/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
        ).readAsBytes().then((bytes) => ByteData.sublistView(bytes)),
      );
    await icons.load();
    for (final name in ['Arial', 'Roboto']) {
      final loader = FontLoader(name)
        ..addFont(
          File(
            '$root/bin/cache/artifacts/material_fonts/Roboto-Regular.ttf',
          ).readAsBytes().then((bytes) => ByteData.sublistView(bytes)),
        );
      await loader.load();
    }
  }

  testWidgets(
    'library groups content, individual selection, queue and narrow layout',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1440, 1000);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(LoaderApp(controller: controller));
      await tester.pumpAndSettle();
      expect(find.text('Orbit Garden'), findsOneWidget);
      expect(find.text('8 games   /   10 packages'), findsOneWidget);
      await tester.tap(find.text('Orbit Garden'));
      await tester.pumpAndSettle();
      expect(find.text('Base (1)'), findsOneWidget);
      expect(find.text('Update (1)'), findsOneWidget);
      expect(find.text('DLC (1)'), findsOneWidget);
      await tester.tap(find.text('Update (1)'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(Checkbox));
      await tester.pumpAndSettle();
      expect(controller.selection.length, 1);
      expect(controller.selection.single.source.name, contains('2800'));
      await tester.tap(find.text('Review queue'));
      await tester.pumpAndSettle();
      expect(find.text('1 selected packages'), findsOneWidget);
      tester.view.physicalSize = const Size(430, 900);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.byIcon(Icons.bolt_rounded));
      await tester.pumpAndSettle();
      expect(find.text('RCM payloads'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byIcon(Icons.tune_rounded));
      await tester.pumpAndSettle();
      expect(find.text('Split & merge'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets('render original synthetic library and details screenshots', (
    tester,
  ) async {
    await tester.runAsync(fonts);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1440, 1000);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final boundary = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundary,
        child: LoaderApp(controller: controller),
      ),
    );
    await tester.pumpAndSettle();
    Future<void> capture(String name) async {
      if (Platform.environment['NSUSB_SCREENSHOTS'] != '1') return;
      await tester.runAsync(() async {
        final image =
            await (boundary.currentContext!.findRenderObject()
                    as RenderRepaintBoundary)
                .toImage(pixelRatio: 1);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await Directory('docs/screenshots').create(recursive: true);
        await File(
          'docs/screenshots/$name.png',
        ).writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }

    await capture('library');
    await tester.tap(find.text('Orbit Garden'));
    await tester.pumpAndSettle();
    await capture('content');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
