// SPDX-License-Identifier: GPL-3.0-or-later
// ignore_for_file: non_constant_identifier_names
import 'dart:ffi';
import 'dart:io';
import 'package:path/path.dart' as p;

class LibUsb {
  final DynamicLibrary library;
  LibUsb() : library = _load();
  static DynamicLibrary _load() {
    final executable = p.dirname(Platform.resolvedExecutable);
    final names = [
      if (Platform.environment['NSUSB_LIBUSB'] != null)
        Platform.environment['NSUSB_LIBUSB']!,
      if (Platform.isMacOS) ...[
        p.join(executable, '../Frameworks/libusb-1.0.dylib'),
        '/opt/homebrew/lib/libusb-1.0.dylib',
        '/usr/local/lib/libusb-1.0.dylib',
        'libusb-1.0.dylib',
      ],
      if (Platform.isLinux) ...[
        p.join(executable, 'lib/libusb-1.0.so.0'),
        'libusb-1.0.so.0',
      ],
      if (Platform.isWindows) p.join(executable, 'libusb-1.0.dll'),
    ];
    for (final name in names) {
      try {
        return DynamicLibrary.open(name);
      } catch (_) {}
    }
    throw StateError(
      'libusb is unavailable. Install libusb or set NSUSB_LIBUSB.',
    );
  }

  late final init = library
      .lookupFunction<
        Int32 Function(Pointer<Pointer<Void>>),
        int Function(Pointer<Pointer<Void>>)
      >('libusb_init');
  late final exit = library
      .lookupFunction<
        Void Function(Pointer<Void>),
        void Function(Pointer<Void>)
      >('libusb_exit');
  late final get_device_list = library
      .lookupFunction<
        IntPtr Function(Pointer<Void>, Pointer<Pointer<Pointer<Void>>>),
        int Function(Pointer<Void>, Pointer<Pointer<Pointer<Void>>>)
      >('libusb_get_device_list');
  late final free_device_list = library
      .lookupFunction<
        Void Function(Pointer<Pointer<Void>>, Int32),
        void Function(Pointer<Pointer<Void>>, int)
      >('libusb_free_device_list');
  late final get_device_descriptor = library
      .lookupFunction<
        Int32 Function(Pointer<Void>, Pointer<Uint8>),
        int Function(Pointer<Void>, Pointer<Uint8>)
      >('libusb_get_device_descriptor');
  late final get_bus_number = library
      .lookupFunction<
        Uint8 Function(Pointer<Void>),
        int Function(Pointer<Void>)
      >('libusb_get_bus_number');
  late final get_device_address = library
      .lookupFunction<
        Uint8 Function(Pointer<Void>),
        int Function(Pointer<Void>)
      >('libusb_get_device_address');
  late final get_port_numbers = library
      .lookupFunction<
        Int32 Function(Pointer<Void>, Pointer<Uint8>, Int32),
        int Function(Pointer<Void>, Pointer<Uint8>, int)
      >('libusb_get_port_numbers');
  late final open = library
      .lookupFunction<
        Int32 Function(Pointer<Void>, Pointer<Pointer<Void>>),
        int Function(Pointer<Void>, Pointer<Pointer<Void>>)
      >('libusb_open');
  late final close = library
      .lookupFunction<
        Void Function(Pointer<Void>),
        void Function(Pointer<Void>)
      >('libusb_close');
  late final get_configuration = library
      .lookupFunction<
        Int32 Function(Pointer<Void>, Pointer<Int32>),
        int Function(Pointer<Void>, Pointer<Int32>)
      >('libusb_get_configuration');
  late final set_configuration = library
      .lookupFunction<
        Int32 Function(Pointer<Void>, Int32),
        int Function(Pointer<Void>, int)
      >('libusb_set_configuration');
  late final claim_interface = library
      .lookupFunction<
        Int32 Function(Pointer<Void>, Int32),
        int Function(Pointer<Void>, int)
      >('libusb_claim_interface');
  late final release_interface = library
      .lookupFunction<
        Int32 Function(Pointer<Void>, Int32),
        int Function(Pointer<Void>, int)
      >('libusb_release_interface');
  late final bulk_transfer = library
      .lookupFunction<
        Int32 Function(
          Pointer<Void>,
          Uint8,
          Pointer<Uint8>,
          Int32,
          Pointer<Int32>,
          Uint32,
        ),
        int Function(
          Pointer<Void>,
          int,
          Pointer<Uint8>,
          int,
          Pointer<Int32>,
          int,
        )
      >('libusb_bulk_transfer');
  late final control_transfer = library
      .lookupFunction<
        Int32 Function(
          Pointer<Void>,
          Uint8,
          Uint8,
          Uint16,
          Uint16,
          Pointer<Uint8>,
          Uint16,
          Uint32,
        ),
        int Function(
          Pointer<Void>,
          int,
          int,
          int,
          int,
          Pointer<Uint8>,
          int,
          int,
        )
      >('libusb_control_transfer');
}
