// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import '../core/files.dart';
import '../core/library.dart';
import 'device.dart';
import 'protocol.dart';
import 'rcm.dart';

Future<List<UsbDevice>> discoverUsb() => Isolate.run(() {
  final context = UsbContext();
  try {
    return context.list();
  } finally {
    context.close();
  }
});
Future<String> runUsbWorker(
  UsbDevice device,
  List<ManifestEntry> entries,
  Cancellation cancel, {
  String? payload,
  void Function(int, int)? onProgress,
}) async {
  final events = ReceivePort();
  final result = Completer<String>();
  SendPort? commands;
  final remove = cancel.listen(() => commands?.send('cancel'));
  final subscription = events.listen((dynamic event) {
    if (event is SendPort) {
      commands = event;
      if (cancel.cancelled) commands!.send('cancel');
    } else if (event is List && event.first == 'progress') {
      onProgress?.call(event[1] as int, event[2] as int);
    } else if (event is List && event.first == 'done') {
      if (!result.isCompleted) result.complete(event[1] as String);
    } else if (event is List && event.first == 'cancelled') {
      if (!result.isCompleted) result.completeError(Cancelled());
    } else if (event is List && event.first == 'error') {
      if (!result.isCompleted) {
        result.completeError(StateError(event[1] as String));
      }
    } else if (event == null && !result.isCompleted) {
      result.completeError(StateError('USB worker exited unexpectedly'));
    }
  });
  try {
    cancel.check();
    await Isolate.spawn(_worker, (
      events.sendPort,
      device,
      entries,
      payload,
    ), onExit: events.sendPort);
    return await result.future;
  } finally {
    remove();
    await subscription.cancel();
    events.close();
  }
}

Future<void> _worker(
  (SendPort, UsbDevice, List<ManifestEntry>, String?) args,
) async {
  final (events, device, entries, payload) = args;
  final commands = ReceivePort();
  final cancel = Cancellation();
  commands.listen((_) => cancel.cancel());
  events.send(commands.sendPort);
  UsbContext? context;
  NativeUsbTransport? transport;
  Object? failure;
  String? message;
  try {
    context = UsbContext();
    transport = context.open(device, cancel);
    if (payload != null) {
      if (!device.rcm) throw StateError('Select an RCM device');
      transport.prepareTrigger();
      final source = await FileSource.open(payload);
      if (source.length < 16384 ||
          source.length > 126296 ||
          source.segments.length != 1) {
        throw const FormatException('Invalid payload file size');
      }
      message = await injectRcm(
        transport,
        await File(payload).readAsBytes(),
        cancel,
      );
    } else {
      if (device.rcm) throw StateError('Select an installer device');
      message = await AwooUsb(
        transport,
        cancel,
        onProgress: (a, b) => events.send(['progress', a, b]),
      ).run(entries);
    }
  } catch (e) {
    failure = e;
  } finally {
    await transport?.close();
    context?.close();
    commands.close();
  }
  if (cancel.cancelled || failure is Cancelled) {
    events.send(['cancelled']);
  } else if (failure != null) {
    events.send(['error', failure.toString()]);
  } else {
    events.send(['done', message!]);
  }
}
