# Upstream and dependencies

This independent Flutter port is based on NS-USBloader by Dmitry Isaenko and its contributors:
https://github.com/developersu/ns-usbloader

Reference revision: e0c7ab3d013feed8d096c0bf0f7db6ea36153c44 (2026-09-19).
License: GPL-3.0-or-later. The original LICENSE is retained.
The port adapts protocol behavior and payload framing; it is not an unmodified copy.
Original Java, JavaFX, Maven and JNI application code is replaced by Dart and a small native USB bridge.
The upstream Git history remains available. No affiliation with the original maintainer is implied.

The RCM design credits the upstream project's fusee-launcher reference:
https://github.com/reswitched/fusee-launcher

Additional components:
- Flutter/Dart: BSD-3-Clause, desktop UI, runtime and generated platform runners.
- libusb: LGPL-2.1-or-later, dynamically loaded USB transport.
- Dart ffi, path, file_selector, path_provider, crypto: preserve the licenses shipped by their packages.
- blawar/TitleDB: MIT, optional downloaded metadata, https://github.com/blawar/titledb.
- Hekate and Atmosphere releases: user-selected external payload providers; downloaded payloads remain outside the source tree and retain their own licenses.

No Java runtime or upstream bundled binary is required by the new application.
Third-party notices must accompany packaged binaries and downloaded metadata.
