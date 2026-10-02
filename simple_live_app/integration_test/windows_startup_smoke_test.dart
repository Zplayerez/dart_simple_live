import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:simple_live_account/simple_live_account.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/main.dart' as app;
import 'package:simple_live_app/modules/indexed/indexed_page.dart';
import 'package:simple_live_app/modules/live_room/player/player_controller.dart';
import 'package:simple_live_app/services/local_storage_service.dart';
import 'package:simple_live_core/simple_live_core.dart';

// Intentionally uses APIs present in v1.11.7 too, so a comparison workflow can
// run this identical harness against the published baseline and the change.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Windows starts with logged-out accounts and can create a player',
      (tester) async {
    expect(Platform.isWindows, isTrue);
    final report = <String, dynamic>{
      'scenario': 'four-logged-out-accounts',
      'mode': kProfileMode ? 'profile' : (kReleaseMode ? 'release' : 'debug'),
      'isolatedProfile': true,
      'credentialStore': 'in-memory fixture',
      'homeNetwork': 'empty local fixtures',
      'measurement': 'Dart main invocation to first rasterized home frame',
    };
    binding.reportData = report;
    // The Windows plugin can fall back to OS credential-manager entries even
    // with an isolated filesystem path. Replace that boundary in both builds.
    FlutterSecureStorage.setMockInitialValues({});
    final root = await Directory.systemTemp.createTemp('simple-live-startup-');
    final previousPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _IsolatedPaths(root.path);
    final originalSites = Map<String, Site>.from(Sites.allSites);
    Sites.allSites.updateAll((id, site) => Site(
          id: id,
          name: site.name,
          logo: site.logo,
          liveSite: LiveSite(id: id),
        ));
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      Get.reset();
      await Hive.close();
      PathProviderPlatform.instance = previousPaths;
      Sites.allSites.addAll(originalSites);
      try {
        await root.delete(recursive: true);
      } on FileSystemException {
        // The baseline can keep a temporary WebView2 profile locked until exit.
      }
    });

    Hive.init(root.path);
    final settings = await Hive.openBox('LocalStorage');
    await settings.putAll({
      LocalStorageService.kFirstRun: false,
      LocalStorageService.kAutoUpdateFollowEnable: false,
      LocalStorageService.kLogEnable: false,
      for (final id in Sites.allSites.keys)
        'PlatformAccountRestoreBlocked.$id': true,
    });
    await Hive.openBox('FollowUser'); // Returning-user profile; no migration.
    await Hive.close();

    final launch = Stopwatch()..start();
    app.main();
    await _waitFor(
        tester, () => find.byType(IndexedPage).evaluate().isNotEmpty);
    await binding.waitUntilFirstFrameRasterized;
    report['dartToFirstHomeMs'] = launch.elapsedMicroseconds / 1000;
    for (final id in Sites.allSites.keys) {
      expect(PlatformAccountManager.instance.account(id).status,
          LiveAccountStatus.signedOut);
    }
    final startupLogs =
        Log.debugLogs.where((entry) => entry.content.startsWith('[Startup] '));
    if (startupLogs.isNotEmpty) {
      report['stages'] =
          jsonDecode(startupLogs.first.content.substring('[Startup] '.length));
    }

    final navigation = Stopwatch()..start();
    await tester.tap(find.byIcon(Constant.allHomePages['user']!.iconData));
    await _waitFor(tester, () => find.text('账号管理').evaluate().isNotEmpty);
    report['navigationToAccountsMs'] = navigation.elapsedMicroseconds / 1000;

    // Also verify that deferring libmpv did not break the first native player.
    // No live URL, real Cookie or external platform is used.
    final playerWatch = Stopwatch()..start();
    final player = _PlayerFactory().createPlayer();
    try {
      await player.setVolume(0);
      report['firstPlayerReadyMs'] = playerWatch.elapsedMicroseconds / 1000;
    } finally {
      await player.dispose();
    }
    expect(tester.takeException(), isNull);
    report['passed'] = true;
  }, timeout: const Timeout(Duration(minutes: 3)));
}

class _PlayerFactory with PlayerMixin {}

class _IsolatedPaths extends PathProviderPlatform {
  _IsolatedPaths(this.root);
  final String root;

  @override
  Future<String?> getApplicationSupportPath() async => root;
  @override
  Future<String?> getApplicationDocumentsPath() async => root;
}

Future<void> _waitFor(WidgetTester tester, bool Function() ready) async {
  final watch = Stopwatch()..start();
  while (!ready()) {
    if (watch.elapsed > const Duration(seconds: 90)) {
      fail('Startup or navigation did not complete within 90 seconds.');
    }
    await tester.pump(const Duration(milliseconds: 16));
  }
}
