// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;
import '../core/files.dart';
import 'libusb_bindings.dart';
import 'protocol.dart';

class UsbDevice {
  final int bus, address, vendor, product;
  final String ports;
  UsbDevice(this.bus, this.address, this.vendor, this.product, this.ports);
  bool get rcm => vendor == 0x0955 && product == 0x7321;
  String get key => '$bus:$address:$ports:$vendor:$product';
  String get label =>
      '${rcm ? 'RCM' : 'Installer'} · Bus $bus / $address · Port $ports';
}

class UsbContext {
  final api = LibUsb();
  Pointer<Void> context = nullptr;
  UsbContext() {
    final ptr = calloc<Pointer<Void>>();
    try {
      _check(api.init(ptr), 'Initialize USB');
      context = ptr.value;
    } finally {
      calloc.free(ptr);
    }
  }
  static void _check(int code, String operation) {
    if (code < 0) throw StateError('$operation: libusb error $code');
  }

  UsbDevice? _info(Pointer<Void> device) {
    final descriptor = calloc<Uint8>(18), ports = calloc<Uint8>(8);
    try {
      _check(
        api.get_device_descriptor(device, descriptor),
        'Read USB descriptor',
      );
      final d = ByteData.sublistView(descriptor.asTypedList(18));
      final vendor = d.getUint16(8, Endian.little),
          product = d.getUint16(10, Endian.little);
      if (!((vendor == 0x0955 && product == 0x7321) ||
          (vendor == 0x057e && product == 0x3000))) {
        return null;
      }
      final count = api.get_port_numbers(device, ports, 8);
      return UsbDevice(
        api.get_bus_number(device),
        api.get_device_address(device),
        vendor,
        product,
        count > 0 ? ports.asTypedList(count).join('.') : 'unknown',
      );
    } finally {
      calloc.free(descriptor);
      calloc.free(ports);
    }
  }

  T _devices<T>(T Function(Pointer<Pointer<Void>>, int) action) {
    final list = calloc<Pointer<Pointer<Void>>>();
    try {
      final count = api.get_device_list(context, list);
      _check(count, 'List USB devices');
      try {
        return action(list.value, count);
      } finally {
        api.free_device_list(list.value, 1);
      }
    } finally {
      calloc.free(list);
    }
  }

  List<UsbDevice> list() => _devices(
    (list, count) => [
      for (var i = 0; i < count; i++)
        if (_info(list[i]) case final UsbDevice device) device,
    ],
  );
  NativeUsbTransport open(UsbDevice selected, Cancellation cancel) {
    return _devices((devices, count) {
      for (var i = 0; i < count; i++) {
        if (_info(devices[i])?.key != selected.key) continue;
        final out = calloc<Pointer<Void>>();
        try {
          _check(api.open(devices[i], out), 'Open selected device');
          final handle = out.value;
          var claimed = false;
          try {
            final config = calloc<Int32>();
            try {
              _check(
                api.get_configuration(handle, config),
                'Read configuration',
              );
              if (config.value != 1) {
                _check(api.set_configuration(handle, 1), 'Set configuration');
              }
            } finally {
              calloc.free(config);
            }
            _check(api.claim_interface(handle, 0), 'Claim interface');
            claimed = true;
            return NativeUsbTransport(this, handle, selected, cancel);
          } catch (_) {
            if (claimed) api.release_interface(handle, 0);
            api.close(handle);
            rethrow;
          }
        } finally {
          calloc.free(out);
        }
      }
      throw StateError(
        'Selected device disconnected. Refresh and select again.',
      );
    });
  }

  void close() {
    if (context != nullptr) {
      api.exit(context);
      context = nullptr;
    }
  }
}

class NativeUsbTransport implements UsbTransport {
  final UsbContext context;
  final Pointer<Void> handle;
  final UsbDevice device;
  final Cancellation cancel;
  bool _closed = false;
  DynamicLibrary? _bridge;
  String? _windowsPath;
  NativeUsbTransport(this.context, this.handle, this.device, this.cancel);

  /// Preflight platform support before sending payload bytes.
  void prepareTrigger() {
    if (Platform.isMacOS) return;
    final base = p.dirname(Platform.resolvedExecutable);
    final name = Platform.isWindows ? 'nsusb_rcm.dll' : 'libnsusb_rcm.so';
    final candidates = [
      if (Platform.environment['NSUSB_RCM_BRIDGE'] != null)
        Platform.environment['NSUSB_RCM_BRIDGE']!,
      p.join(base, Platform.isWindows ? '' : 'lib', name),
      p.join(Directory.current.path, 'build/native', name),
    ];
    for (final path in candidates) {
      try {
        _bridge = DynamicLibrary.open(path);
        break;
      } catch (_) {}
    }
    if (_bridge == null) {
      throw StateError('RCM native bridge missing; build native/ first.');
    }
    if (Platform.isWindows) {
      final buffer = calloc<Uint8>(4096);
      try {
        final status = _bridge!
            .lookupFunction<
              Int32 Function(Pointer<Uint8>, Int32),
              int Function(Pointer<Uint8>, int)
            >('ns_windows_rcm_path')(buffer, 4096);
        if (status != 0) {
          throw StateError(
            'Windows RCM preflight $status: connect one RCM device with libusbK/libusb-win32 driver.',
          );
        }
        _windowsPath = buffer.cast<Utf8>().toDartString();
      } finally {
        calloc.free(buffer);
      }
    }
  }

  @override
  Future<Uint8List> read(int maxLength) async {
    final buffer = calloc<Uint8>(maxLength), transferred = calloc<Int32>();
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    try {
      while (true) {
        cancel.check();
        final result = context.api.bulk_transfer(
          handle,
          0x81,
          buffer,
          maxLength,
          transferred,
          500,
        );
        if (transferred.value > 0) {
          if (result != 0 && result != -7) {
            UsbContext._check(result, 'Read USB');
          }
          return Uint8List.fromList(buffer.asTypedList(transferred.value));
        }
        if (result != 0 && result != -7) UsbContext._check(result, 'Read USB');
        if (DateTime.now().isAfter(deadline)) {
          throw const SocketException('USB request timed out');
        }
        await Future<void>.delayed(Duration.zero);
      }
    } finally {
      calloc.free(buffer);
      calloc.free(transferred);
    }
  }

  @override
  Future<void> write(Uint8List data) async {
    final buffer = calloc<Uint8>(data.length), transferred = calloc<Int32>();
    buffer.asTypedList(data.length).setAll(0, data);
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    try {
      var offset = 0;
      while (offset < data.length) {
        cancel.check();
        final result = context.api.bulk_transfer(
          handle,
          1,
          buffer + offset,
          data.length - offset,
          transferred,
          500,
        );
        if (result != 0 && result != -7) UsbContext._check(result, 'Write USB');
        if (transferred.value < 0 || transferred.value > data.length - offset) {
          throw StateError('Invalid USB transfer length');
        }
        offset += transferred.value;
        // Never resend bytes already accepted during a timeout.
        if (DateTime.now().isAfter(deadline) && offset < data.length) {
          throw const SocketException('USB write timed out');
        }
        await Future<void>.delayed(Duration.zero);
      }
    } finally {
      calloc.free(buffer);
      calloc.free(transferred);
    }
  }

  @override
  Future<int> trigger() async {
    cancel.check();
    if (Platform.isMacOS) {
      final buffer = calloc<Uint8>(0x7000);
      try {
        return context.api.control_transfer(
          handle,
          0x82,
          0,
          0,
          0,
          buffer,
          0x7000,
          1000,
        );
      } finally {
        calloc.free(buffer);
      }
    }
    if (_bridge == null) throw StateError('Trigger not prepared');
    if (Platform.isLinux) {
      return _bridge!
          .lookupFunction<Int32 Function(Int32, Int32), int Function(int, int)>(
            'ns_linux_rcm_trigger',
          )(device.bus, device.address);
    }
    final path = _windowsPath!.toNativeUtf8();
    try {
      return _bridge!.lookupFunction<
        Int32 Function(Pointer<Utf8>),
        int Function(Pointer<Utf8>)
      >('ns_windows_rcm_trigger')(path);
    } finally {
      calloc.free(path);
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    context.api.release_interface(handle, 0);
    context.api.close(handle);
  }
}
