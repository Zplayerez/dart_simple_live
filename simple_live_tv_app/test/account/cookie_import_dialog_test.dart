import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:simple_live_account/simple_live_account.dart';
import 'package:simple_live_core/simple_live_core.dart';
import 'package:simple_live_tv_app/modules/account/account_page.dart';
import 'package:simple_live_tv_app/widgets/button/highlight_list_tile.dart';
import 'package:simple_live_tv_app/modules/account/cookie_import_dialog.dart';
import 'package:simple_live_tv_app/widgets/button/highlight_button.dart';

void main() {
  tearDown(() => Get.reset());

  testWidgets(
      'remote opens account update without treating failed verification as login',
      (tester) async {
    Get.testMode = true;
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final manager = Get.put(
        PlatformAccountManager(sites: {'douyin': LiveSite()..id = 'douyin'}));
    manager.accounts['douyin'] = const PlatformAccountState(
      siteId: 'douyin',
      status: LiveAccountStatus.unavailable,
      persistence: AccountPersistence.sessionOnly,
      hasCredential: true,
      message: '暂时无法验证，凭据已保留',
    );
    await tester.pumpWidget(ScreenUtilInit(
      designSize: const Size(1920, 1080),
      builder: (_, __) => GetMaterialApp(
          theme: ThemeData.dark(), home: const AccountPage(siteId: 'douyin')),
    ));
    await tester.pumpAndSettle();
    expect(find.text('暂时无法验证 · 仅本次会话'), findsOneWidget);
    expect(find.textContaining('已验证登录'), findsNothing);
    final update = find.widgetWithText(HighlightListTile, '更新 Cookie');
    await tester.ensureVisible(update);
    final button = tester.widget<HighlightListTile>(update);
    button.focusNode.requestFocus();
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    final input = tester.widget<TextField>(find.byType(TextField));
    expect(input.controller!.text, isEmpty);
    expect(input.obscureText, isTrue);
    final cancel = tester
        .widget<HighlightButton>(find.widgetWithText(HighlightButton, '取消'));
    cancel.focusNode.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNothing);
    expect(manager.account('douyin').status, LiveAccountStatus.unavailable);
    expect(tester.takeException(), isNull);
  });

  testWidgets('remote navigates masked Cookie input and saves full header',
      (tester) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    String? result;
    await tester.pumpWidget(ScreenUtilInit(
      designSize: const Size(1920, 1080),
      builder: (_, __) => MaterialApp(
        theme: ThemeData.dark(),
        home: Builder(
            builder: (context) => Scaffold(
                  body: TextButton(
                    onPressed: () async {
                      result = await showDialog<String>(
                          context: context,
                          builder: (_) =>
                              const CookieImportDialog(siteId: 'douyin'));
                    },
                    child: const Text('open'),
                  ),
                )),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    final input = tester.widget<TextField>(find.byType(TextField));
    expect(input.obscureText, isTrue);
    expect(input.controller!.text, isEmpty);
    await tester.enterText(
        find.byType(TextField), 'sessionid=synthetic-token; ttwid=device');
    input.focusNode!.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    final visibility = tester.widget<HighlightButton>(
        find.widgetWithText(HighlightButton, '显示本次输入'));
    expect(visibility.focusNode.hasFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(
        tester.widget<TextField>(find.byType(TextField)).obscureText, isFalse);

    final save = tester
        .widget<HighlightButton>(find.widgetWithText(HighlightButton, '保存并验证'));
    save.focusNode.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(result, 'sessionid=synthetic-token; ttwid=device');
    expect(tester.takeException(), isNull);
  });
}
