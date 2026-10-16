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
import '../services/library_service.dart';
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
  LibraryService? _library;
  LibraryService get library =>
      _library ?? (throw StateError('Library has not initialized'));
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
      _library = await LibraryService.open(data);
      await library.migrateLegacy(
        folders: preferences.folders,
        overrides: preferences.overrides,
      );
      catalog = await catalogStore.load(
        preferences.region,
        fallback: preferences.englishFallback ? 'US.en' : preferences.region,
      );
      library.updateTitleMetadata(catalog);
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
      scanIssues = await library.scan(cancel: scanCancel);
      packages = library.packages.map((item) => item.package).toList();
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
    await library.addSource(path);
    await scan();
  }

  Future<void> addFiles(Iterable<String> paths) async {
    for (final path in paths) {
      await library.addSource(path);
    }
    await scan();
  }

  Future<void> removeFolder(String path) async {
    preferences.folders.remove(path);
    await preferences.save();
    final source = library.sources
        .where((source) => source.path == p.normalize(p.absolute(path)))
        .firstOrNull;
    if (source != null) library.removeSource(source.id);
    await scan();
  }

  Future<void> removeSource(String id) async {
    final source = library.sources
        .where((source) => source.id == id)
        .firstOrNull;
    if (source == null) return;
    preferences.folders.remove(source.path);
    await preferences.save();
    library.removeSource(id);
    await scan();
  }

  void setSourcePublished(String id, bool published) {
    library.updateSource(id, published: published);
    notifyListeners();
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
      library.updateTitleMetadata(catalog);
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
    library.setOverride(package, value);
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
    final library = _library;
    if (library != null) unawaited(library.close());
    super.dispose();
  }
}
