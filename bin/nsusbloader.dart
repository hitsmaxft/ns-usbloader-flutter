// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:ns_usbloader/core/files.dart';
import 'package:ns_usbloader/core/library.dart';
import 'package:ns_usbloader/services/downloads.dart';
import 'package:ns_usbloader/services/network.dart';
import 'package:ns_usbloader/services/library_daemon.dart';
import 'package:ns_usbloader/services/library_service.dart';
import 'package:ns_usbloader/usb/worker.dart';

const usage = '''NS-USBloader Flutter CLI (no Java)
  scan <folder>...
  split <file> <new-directory> [chunk-bytes]
  merge <split-directory> <new-file>
  usb-list
  usb <device-key> <package>...
  network <console-ip> <host-ip> <package>...
  payload-list <hekate|fusee> <external-cache-directory>
  payload-download <hekate|fusee> <tag> <external-cache-directory>
  rcm-inject <device-key> <payload.bin>
  library-add <data-directory> <directory-or-package>...
  library-scan <data-directory>
  library-serve <absolute-config.json>
Network serving ends with Ctrl-C. Byte delivery is not installation confirmation.
''';
Future<void> main(List<String> args) async {
  if (args.isEmpty || args.first == '--help') {
    stdout.write(usage);
    return;
  }
  final cancel = Cancellation();
  final signal = ProcessSignal.sigint.watch().listen((_) => cancel.cancel());
  void need(int count) {
    if (args.length < count) throw ArgumentError(usage);
  }

  try {
    switch (args.first) {
      case 'scan':
        need(2);
        final result = await LibraryScanner().scan(
          args.sublist(1),
          cancel: cancel,
        );
        stdout.writeln(
          const JsonEncoder.withIndent('  ').convert({
            'packages': [
              for (final item in result.packages)
                {
                  'path': item.source.path,
                  'size': item.source.length,
                  'id': item.titleId,
                  'evidence': item.evidence.name,
                  'kind': item.kind.name,
                  'group': item.groupId,
                  'version': item.version,
                },
            ],
            'issues': result.issues,
          }),
        );
      case 'split':
        need(3);
        await splitFile(
          await FileSource.open(args[1]),
          args[2],
          chunkSize: args.length > 3 ? int.parse(args[3]) : 0xffff0000,
          cancel: cancel,
        );
      case 'merge':
        need(3);
        await mergeFile(
          await FileSource.open(args[1]),
          args[2],
          cancel: cancel,
        );
      case 'usb-list':
        for (final device in await discoverUsb()) {
          stdout.writeln('${device.key}\t${device.label}');
        }
      case 'usb':
      case 'rcm-inject':
        need(3);
        final devices = await discoverUsb();
        final device = devices.where((d) => d.key == args[1]).firstOrNull;
        if (device == null) throw StateError('Device not found; run usb-list');
        final inject = args.first == 'rcm-inject';
        final entries = inject
            ? <ManifestEntry>[]
            : manifest(
                (await LibraryScanner().scan(
                  args.sublist(2),
                  cancel: cancel,
                )).packages,
              );
        stdout.writeln(
          await runUsbWorker(
            device,
            entries,
            cancel,
            payload: inject ? args[2] : null,
            onProgress: (a, b) => stderr.writeln('$a/$b bytes'),
          ),
        );
      case 'network':
        need(4);
        final entries = manifest(
          (await LibraryScanner().scan(
            args.sublist(3),
            cancel: cancel,
          )).packages,
        );
        final transfer = NetworkTransfer(
          entries,
          cancel,
          onProgress: (a, b) => stderr.writeln('$a/$b bytes served'),
          onError: stderr.writeln,
        );
        try {
          await transfer.serve(args[2]);
          await transfer.advertise(args[1], args[2]);
          stdout.writeln(
            'Serving ${entries.length} selected packages on ${args[2]}:${transfer.port}. Ctrl-C to cancel.',
          );
          final stopped = Completer<void>();
          final remove = cancel.listen(() => stopped.complete());
          await stopped.future;
          remove();
          stdout.writeln('Cancelled. Installation not verified.');
        } finally {
          await transfer.close();
        }
      case 'payload-list':
      case 'payload-download':
        final download = args.first == 'payload-download';
        need(download ? 4 : 3);
        final provider = PayloadProvider(Directory(args[download ? 3 : 2]));
        final project = PayloadProject.values.byName(args[1]);
        final releases = await provider.releases(project, cancel: cancel);
        if (download) {
          final release = releases.where((r) => r.tag == args[2]).firstOrNull;
          if (release == null) {
            throw StateError(
              'Tag has no supported payload in the latest 30 releases',
            );
          }
          stdout.writeln(
            (await provider.download(release, cancel: cancel)).path,
          );
        } else {
          for (final r in releases) {
            stdout.writeln(
              '${r.tag}\t${r.name}\t${r.digest ?? "No published digest"}',
            );
          }
        }
      case 'library-add':
        need(3);
        final library = await LibraryService.open(Directory(args[1]));
        try {
          for (final path in args.sublist(2)) {
            final source = await library.addSource(path);
            stdout.writeln('${source.id}\t${source.kind.name}\t${source.path}');
          }
        } finally {
          await library.close();
        }
      case 'library-scan':
        need(2);
        final library = await LibraryService.open(Directory(args[1]));
        try {
          final issues = await library.scan(cancel: cancel);
          stdout.writeln(
            'Committed ${library.revision} with ${library.packages.length} packages',
          );
          for (final issue in issues) {
            stderr.writeln(issue);
          }
        } finally {
          await library.close();
        }
      case 'library-serve':
        need(2);
        final config = await LibraryDaemonConfig.load(File(args[1]));
        final daemon = await LibraryDaemon.start(config, log: stderr.writeln);
        try {
          final stopped = Completer<void>();
          final remove = cancel.listen(stopped.complete);
          await stopped.future;
          remove();
        } finally {
          await daemon.close();
        }
      default:
        throw ArgumentError(usage);
    }
  } on Cancelled {
    stderr.writeln('Cancelled');
    exitCode = 130;
  } catch (e) {
    stderr.writeln(e);
    exitCode = 1;
  } finally {
    await signal.cancel();
  }
}
