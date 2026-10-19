import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:simple_live_tv_app/widgets/button/highlight_button.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:simple_live_tv_app/modules/sync/sync_controller.dart';
import 'package:simple_live_tv_app/modules/sync/sync_page.dart';
import 'package:simple_live_tv_app/services/signalr_service.dart';
import 'package:simple_live_tv_app/services/sync_service.dart';

class FixtureLocalSync extends SyncService {
  int starts = 0;
  @override
  Future<void> initServer() async {
    starts++;
  }

  @override
  Future<void> listenUDP() async {}
}

class FixtureRemoteSync extends SignalRService {
  int connections = 0;
  @override
  Future<void> connect() async {
    connections++;
  }

  @override
  Future<Resp<String>> createRoom() async => Resp(true, '', 'ABCDE');
}

void main() {
  tearDown(() => Get.reset());
  testWidgets(
      'LAN is usable without creating a room and no placeholder QR is shown',
      (tester) async {
    Get.testMode = true;
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final local = FixtureLocalSync()
      ..httpRunning.value = true
      ..ipAddress.value = '192.168.1.2';
    final remote = FixtureRemoteSync();
    Get.put<SyncService>(local);
    final controller = Get.put(SyncController(remoteService: remote));
    await tester.pumpWidget(ScreenUtilInit(
        designSize: const Size(1920, 1080),
        builder: (_, __) => const GetMaterialApp(home: SyncPage())));
    await tester.pumpAndSettle();
    expect(remote.connections, 0);
    expect(find.byType(QrImageView), findsOneWidget);
    expect(find.byKey(const ValueKey('local-sync-qr')), findsOneWidget);
    expect(find.byKey(const ValueKey('remote-sync-qr')), findsNothing);
    expect(find.text('同一 Wi-Fi 直接同步'), findsOneWidget);
    final previousStarts = local.starts;
    tester
        .widget<HighlightButton>(find.widgetWithText(HighlightButton, '刷新本机连接'))
        .focusNode
        .requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(local.starts, previousStarts + 1);
    tester
        .widget<HighlightButton>(find.widgetWithText(HighlightButton, '创建远程房间'))
        .focusNode
        .requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(remote.connections, 1);
    expect(find.byType(QrImageView), findsNWidgets(2));
    expect(find.byKey(const ValueKey('remote-sync-qr')), findsOneWidget);
    expect(controller.currentRoomId.value, 'ABCDE');
    await Get.delete<SyncController>();
    await tester.pumpWidget(const SizedBox());
  });
}
