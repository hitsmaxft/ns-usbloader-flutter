// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import '../core/files.dart';
import '../core/library.dart';
import '../services/catalog.dart';
import '../services/downloads.dart';
import '../services/network.dart';
import '../usb/device.dart';
import '../usb/worker.dart';

class TransferJob {
  final String title;
  final List<ManifestEntry> entries;
  final Cancellation cancel = Cancellation();
  String status = 'Starting';
  int done = 0, total = 0;
  bool active = true;
  TransferJob(this.title, this.entries);
  double? get progress => total == 0 ? null : done / total;
}

class AppController extends ChangeNotifier {
  final Directory data;
  late final preferences = Preferences(
    File(p.join(data.path, 'preferences.json')),
  );
  late final catalogStore = CatalogStore(
    Directory(p.join(data.path, 'catalog')),
  );
  late final payloads = PayloadProvider(
    Directory(p.join(data.path, 'payloads')),
  );
  final scanner = LibraryScanner();
  Catalog catalog = Catalog();
  List<Package> packages = [];
  final selected = <String>{};
  List<String> scanIssues = [];
  List<UsbDevice> devices = [];
  UsbDevice? device;
  final jobs = <TransferJob>[];
  bool scanning = false, refreshingCatalog = false, usbBusy = false;
  Cancellation? scanCancel, catalogCancel;
  String? error;
  AppController(this.data);
  List<GameGroup> get groups => groupPackages(packages);
  List<ManifestEntry> get selection =>
      manifest(packages.where((p) => selected.contains(p.key)));
  void changed() => notifyListeners();
  Future<void> initialize() async {
    try {
      await preferences.load();
      catalog = await catalogStore.load(
        preferences.region,
        fallback: preferences.englishFallback ? 'US.en' : preferences.region,
      );
      await scan();
    } catch (e) {
      error = e.toString();
      notifyListeners();
    }
  }

  Future<void> scan() async {
    if (scanning) return;
    scanning = true;
    scanCancel = Cancellation();
    notifyListeners();
    try {
      final result = await scanner.scan(
        preferences.folders,
        cancel: scanCancel,
        overrides: preferences.overrides,
      );
      packages = result.packages;
      scanIssues = result.issues;
      selected.removeWhere((key) => !packages.any((p) => p.key == key));
    } on Cancelled {
      /* Preserve the last completed snapshot. */
    } catch (e) {
      error = e.toString();
    } finally {
      scanning = false;
      notifyListeners();
    }
  }

  Future<void> addFolder(String path) async {
    if (!preferences.folders.contains(path)) preferences.folders.add(path);
    await preferences.save();
    await scan();
  }

  Future<void> removeFolder(String path) async {
    preferences.folders.remove(path);
    await preferences.save();
    await scan();
  }

  void toggle(Package item, bool value) {
    value ? selected.add(item.key) : selected.remove(item.key);
    notifyListeners();
  }

  Future<void> refreshCatalog(String region, {bool fallback = true}) async {
    if (refreshingCatalog) return;
    refreshingCatalog = true;
    catalogCancel = Cancellation();
    notifyListeners();
    try {
      await catalogStore.refresh(region, cancel: catalogCancel);
      if (fallback && region != 'US.en') {
        await catalogStore.refresh('US.en', cancel: catalogCancel);
      }
      preferences.region = region;
      preferences.englishFallback = fallback;
      await preferences.save();
      catalog = await catalogStore.load(
        region,
        fallback: fallback ? 'US.en' : region,
      );
    } on Cancelled {
      /* Keep the previous catalog. */
    } catch (e) {
      error = e.toString();
    } finally {
      refreshingCatalog = false;
      notifyListeners();
    }
  }

  Future<void> refreshDevices() async {
    devices = await discoverUsb();
    final key = device?.key;
    device = devices.where((d) => d.key == key).firstOrNull;
    notifyListeners();
  }

  void chooseDevice(UsbDevice? value) {
    device = value;
    notifyListeners();
  }

  Future<void> setIdentity(Package package, Map<String, dynamic>? value) async {
    if (value == null) {
      preferences.overrides.remove(package.source.path);
    } else {
      preferences.overrides[package.source.path] = value;
    }
    await preferences.save();
    await scan();
  }

  Future<void> startNetwork(String console, String host, {int port = 0}) async {
    final entries = selection;
    if (entries.isEmpty) throw StateError('Select content first');
    final job = TransferJob('Awoo · Network', entries);
    jobs.insert(0, job);
    notifyListeners();
    final transfer = NetworkTransfer(
      entries,
      job.cancel,
      onProgress: (a, b) {
        job.done = a;
        job.total = b;
        job.status = a == b
            ? 'All bytes served · installation unverified'
            : 'Serving selected content';
        notifyListeners();
      },
      onError: (e) {
        job.status = 'Request failed: $e';
        notifyListeners();
      },
    );
    job.cancel.listen(() {
      job.status = 'Cancelled';
      job.active = false;
      notifyListeners();
    });
    try {
      await transfer.serve(host, port: port);
      await transfer.advertise(console, host);
      if (!job.cancel.cancelled) job.status = 'Waiting for console requests';
    } catch (e) {
      await transfer.close();
      job.status = job.cancel.cancelled ? 'Cancelled' : 'Failed: $e';
      job.active = false;
    }
    notifyListeners();
  }

  Future<void> startUsb({String? payload}) async {
    if (usbBusy) throw StateError('USB is busy');
    final selectedDevice = device;
    if (selectedDevice == null) throw StateError('Choose a device');
    if (payload == null && selection.isEmpty) {
      throw StateError('Select content first');
    }
    final job = TransferJob(
      payload == null ? 'Awoo · USB' : 'RCM · ${p.basename(payload)}',
      payload == null ? selection : [],
    );
    jobs.insert(0, job);
    usbBusy = true;
    notifyListeners();
    try {
      job.status = payload == null
          ? 'Waiting for installer'
          : 'Sending payload';
      job.status = await runUsbWorker(
        selectedDevice,
        job.entries,
        job.cancel,
        payload: payload,
        onProgress: (a, b) {
          job.done = a;
          job.total = b;
          notifyListeners();
        },
      );
    } on Cancelled {
      job.status = 'Cancelled';
    } catch (e) {
      job.status = 'Failed: $e';
    } finally {
      job.active = false;
      usbBusy = false;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    scanCancel?.cancel();
    catalogCancel?.cancel();
    for (final job in jobs) {
      if (job.active) job.cancel.cancel();
    }
    super.dispose();
  }
}
