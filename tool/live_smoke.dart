// Read-only USB discovery and bounded public downloads. Never injects or installs.
import 'dart:io';
import 'package:ns_usbloader/services/catalog.dart';
import 'package:ns_usbloader/services/downloads.dart';
import 'package:ns_usbloader/usb/worker.dart';

Future<void> main(List<String> args) async {
  final temp = await Directory.systemTemp.createTemp('nsusb-live-smoke-');
  Future<void> check(String label, Future<void> Function() run) async {
    try {
      await run();
    } catch (e) {
      stderr.writeln('$label: $e');
      exitCode = 1;
    }
  }

  try {
    if (args.isEmpty || args.contains('usb')) {
      await check('USB', () async {
        final devices = await discoverUsb();
        stdout.writeln(
          'USB enumeration: ${devices.length} matching devices (no claims or writes)',
        );
      });
    }
    final provider = PayloadProvider(Directory('${temp.path}/payloads'));
    if (args.isEmpty || args.contains('payloads')) {
      await check('Hekate', () async {
        final releases = await provider.releases(PayloadProject.hekate);
        if (releases.isEmpty) {
          throw StateError('No official Hekate payload releases');
        }
        final release = releases.first;
        final file = await provider.download(release);
        final cached = await provider.download(release);
        if (file.path != cached.path) {
          throw StateError('Cache identity mismatch');
        }
        stdout.writeln(
          'Hekate ${release.tag}: ${await file.length()} bytes, published SHA-256 ${release.digest != null ? 'verified' : 'unavailable'}, cache reused',
        );
      });
    }
    if (args.isEmpty || args.contains('payloads')) {
      await check('Atmosphere', () async {
        final fusee = await provider.releases(PayloadProject.fusee);
        stdout.writeln(
          'Atmosphere: ${fusee.length} explicit fusee versions discovered (not downloaded)',
        );
      });
    }
    if (args.isEmpty || args.contains('catalog')) {
      await check('Title DB', () async {
        final catalog = CatalogStore(Directory('${temp.path}/catalog'));
        await catalog.refresh('CN.zh');
        await catalog.refresh('CN.zh');
        final titles = await catalog.load('CN.zh', fallback: 'CN.zh');
        stdout.writeln(
          'Title DB CN.zh: ${titles.titles.length} display-only records; conditional refresh completed',
        );
      });
    }
  } finally {
    await temp.delete(recursive: true);
  }
}
