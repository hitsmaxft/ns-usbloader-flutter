// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'ui/app.dart';
import 'ui/controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks([
      'NS-USBloader Flutter',
    ], await rootBundle.loadString('LICENSE'));
    yield LicenseEntryWithLineBreaks([
      'NS-USBloader upstream attribution',
    ], await rootBundle.loadString('docs/UPSTREAM.md'));
    yield LicenseEntryWithLineBreaks([
      'blawar/TitleDB',
    ], await rootBundle.loadString('docs/TitleDB-LICENSE'));
  });
  final controller = AppController(await getApplicationSupportDirectory());
  runApp(LoaderApp(controller: controller));
  await controller.initialize();
}
