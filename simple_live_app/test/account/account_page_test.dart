import 'package:flutter/material.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:simple_live_account/simple_live_account.dart';
import 'package:simple_live_app/modules/mine/account/account_controller.dart';
import 'package:simple_live_app/modules/mine/account/account_page.dart';
import 'package:simple_live_core/simple_live_core.dart';

class UnavailableStore implements CredentialStore {
  @override
  Future<String?> read(String siteId) async => null;
  @override
  Future<void> write(String siteId, String cookie) async =>
      throw StateError('unavailable');
  @override
  Future<void> delete(String siteId) async {}
}

void main() {
  tearDown(() => Get.reset());

  testWidgets(
      'failed verification keeps credentials private and allows replacement',
      (tester) async {
    Get.testMode = true;
    final manager = Get.put(PlatformAccountManager(
      sites: {
        for (final id in ['bilibili', 'douyu', 'huya', 'douyin'])
          id: LiveSite()..id = id
      },
      store: UnavailableStore(),
      verifier: (_) async => const LiveAccountValidation(
        status: LiveAccountStatus.unavailable,
        message: '暂时无法验证，已保留凭据',
      ),
    ));
    await manager.importCookie(
        'douyin', 'sessionid=synthetic-old; ttwid=device');
    Get.put(AccountController());
    await tester.pumpWidget(GetMaterialApp(
      builder: FlutterSmartDialog.init(),
      home: const AccountPage(),
    ));
    await tester.pumpAndSettle();
    expect(find.text('暂时无法验证 · 仅本次会话'), findsOneWidget);
    expect(find.textContaining('已验证登录'), findsNothing);
    expect(find.textContaining('synthetic-old'), findsNothing);
    expect(find.text('斗鱼直播'), findsOneWidget);
    expect(find.text('虎牙直播'), findsOneWidget);

    await tester.tap(find.text('抖音直播'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('更新 Cookie'));
    await tester.pumpAndSettle();
    var field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller!.text, isEmpty);
    expect(field.obscureText, isTrue);
    await tester.enterText(
        find.byType(TextField), 'sessionid=synthetic-discarded');
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(manager.credentialFor('douyin'), contains('synthetic-old'));

    await tester.tap(find.text('更新 Cookie'));
    await tester.pumpAndSettle();
    field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller!.text, isEmpty);
    await tester.enterText(
        find.byType(TextField), 'sessionid=synthetic-new; ttwid=device');
    await tester.tap(find.text('保存并验证'));
    await tester.pumpAndSettle();
    expect(manager.credentialFor('douyin'),
        'sessionid=synthetic-new; ttwid=device');
    expect(manager.account('douyin').status, LiveAccountStatus.unavailable);
    expect(find.textContaining('已验证登录'), findsNothing);
    expect(find.textContaining('synthetic-new'), findsNothing);
    SmartDialog.dismiss(status: SmartStatus.allToast);
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
  });
}
