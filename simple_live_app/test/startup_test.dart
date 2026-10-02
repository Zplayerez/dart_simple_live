import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/app/startup_timings.dart';
import 'package:simple_live_app/main.dart' as app;
import 'package:simple_live_app/modules/indexed/indexed_controller.dart';
import 'package:simple_live_app/modules/indexed/indexed_page.dart';
import 'package:simple_live_app/services/db_service.dart';
import 'package:simple_live_app/services/local_storage_service.dart';
import 'package:simple_live_app/services/sync_service.dart';
import 'package:simple_live_core/simple_live_core.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final originalSites = Map<String, Site>.from(Sites.allSites);
  late Directory directory;

  setUp(() async {
    Get.testMode = true;
    directory = await Directory.systemTemp.createTemp('simple-live-startup-');
    Hive.init(directory.path);
    PackageInfo.setMockInitialValues(
      appName: 'Simple Live',
      packageName: 'startup.test',
      version: '0.0.0',
      buildNumber: '0',
      buildSignature: '',
    );
    // No website or real credential store is used by these startup fixtures.
    Sites.allSites.updateAll((id, site) => Site(
          id: id,
          name: site.name,
          logo: site.logo,
          liveSite: LiveSite(id: id),
        ));
  });

  tearDown(() async {
    Get.reset();
    await Hive.close();
    Hive.resetAdapters();
    Sites.allSites.addAll(originalSites);
    await directory.delete(recursive: true);
  });

  for (final home in Constant.allHomePages.keys) {
    testWidgets('$home can be the first page with all required services ready',
        (tester) async {
      await tester.runAsync(() async {
        final settings = await Hive.openBox('LocalStorage');
        await settings.putAll({
          LocalStorageService.kFirstRun: false,
          LocalStorageService.kLogEnable: false,
          LocalStorageService.kAutoUpdateFollowEnable: false,
          LocalStorageService.kHomeSort: [
            home,
            ...Constant.allHomePages.keys.where((key) => key != home),
          ].join(','),
          for (final id in Sites.allSites.keys)
            'PlatformAccountRestoreBlocked.$id': true,
        });
        await app.initServices(StartupTimings());
      });
      expect(DBService.instance.followBox.isOpen, isTrue);
      expect(DBService.instance.historyBox.isOpen, isTrue);
      expect(DBService.instance.tagBox.isOpen, isTrue);
      expect(LocalStorageService.instance.shieldBox.isOpen, isTrue);
      expect(Get.isPrepared<SyncService>(), isTrue,
          reason: 'Sync must be available without starting network listeners.');

      await tester.pumpWidget(const app.MyApp());
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(IndexedPage), findsOneWidget);
      expect(Get.find<IndexedController>().items.first.index,
          Constant.allHomePages[home]!.index);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
    });
  }
}
