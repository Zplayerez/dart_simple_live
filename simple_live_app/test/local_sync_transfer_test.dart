import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:hive/hive.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/models/db/follow_user_tag.dart';
import 'package:simple_live_app/models/db/history.dart';
import 'package:simple_live_app/models/sync_client_info_model.dart';
import 'package:simple_live_app/modules/sync/local_sync/device/sync_device_controller.dart';
import 'package:simple_live_app/requests/sync_client_request.dart';
import 'package:simple_live_app/services/db_service.dart';
import 'package:simple_live_app/services/sync_service.dart';

class LoopbackHttpOverrides extends HttpOverrides {}

class FixtureReceiver extends SyncService {
  @override
  Future<String> getDeviceName() async => '合成测试设备';
}

class RecordingSender extends SyncClientRequest {
  int follows = 0;
  int tags = 0;
  @override
  Future<bool> syncFollow(SyncClinet client, dynamic body,
      {bool overlay = false}) async {
    follows++;
    return true;
  }

  @override
  Future<bool> syncTag(SyncClinet client, dynamic body,
      {bool overlay = false}) async {
    tags++;
    throw StateError('TV has no tag endpoint');
  }
}

class FixtureSenderController extends SyncDeviceController {
  FixtureSenderController({required super.client, required super.info});
  @override
  Future<bool> showOverlayDialog() async => false;
}

FollowUser follow(String id) => FollowUser(
    id: id,
    roomId: id,
    siteId: 'douyu',
    userName: '合成数据',
    face: '',
    addTime: DateTime(2026, 1, 1));

void main() {
  late Directory directory;
  late DBService db;
  setUp(() async {
    Get.testMode = true;
    directory =
        await Directory.systemTemp.createTemp('simple-live-local-sync-test-');
    Hive.init(directory.path);
    if (!Hive.isAdapterRegistered(1)) Hive.registerAdapter(FollowUserAdapter());
    if (!Hive.isAdapterRegistered(2)) Hive.registerAdapter(HistoryAdapter());
    if (!Hive.isAdapterRegistered(3)) {
      Hive.registerAdapter(FollowUserTagAdapter());
    }
    db = DBService();
    await db.init();
    Get.put(db);
    Utils.packageInfo = PackageInfo(
        appName: 'fixture',
        packageName: 'fixture',
        version: '1.0.0',
        buildNumber: '1');
  });
  tearDown(() async {
    Get.reset();
    await Hive.close();
    await directory.delete(recursive: true);
  });

  testWidgets('real loopback HTTP sends follows and validates before overwrite',
      (tester) async {
    await tester.pumpWidget(GetMaterialApp(
        builder: FlutterSmartDialog.init(),
        home: const Scaffold(body: Text('fixture'))));
    await tester.runAsync(() => HttpOverrides.runWithHttpOverrides(() async {
          final receiver = FixtureReceiver()..ipAddress.value = '127.0.0.1';
          final server = await shelf_io.serve(
              receiver.createHandler(), InternetAddress.loopbackIPv4, 0);
          final client = SyncClinet(
              id: 'test',
              name: 'test',
              address: '127.0.0.1',
              port: server.port,
              type: 'windows');
          final sender = SyncClientRequest();
          try {
            final info = await sender.getClientInfo(client);
            expect(info.name, '合成测试设备');
            expect(info.supportsFollowTags, isTrue);
            await db.followBox.put('old', follow('old'));
            await expectLater(
                sender.syncFollow(
                    client,
                    jsonEncode([
                      follow('new').toJson(),
                      {'id': 'invalid'}
                    ]),
                    overlay: true),
                throwsA(anything));
            expect(db.followBox.keys, ['old']);
            expect(
                await sender.syncFollow(
                    client, jsonEncode([follow('new').toJson()])),
                isTrue);
            expect(db.followBox.keys.toSet(), {'old', 'new'});
            expect(
                await sender.syncFollow(
                    client, jsonEncode([follow('replacement').toJson()]),
                    overlay: true),
                isTrue);
            expect(db.followBox.keys, ['replacement']);
          } finally {
            await server.close(force: true);
          }
        }, LoopbackHttpOverrides()));
    SmartDialog.dismiss(status: SmartStatus.allToast);
    await tester.pumpAndSettle();
  });

  testWidgets(
      'TV receives follows without requesting its nonexistent tag endpoint',
      (tester) async {
    await tester.pumpWidget(GetMaterialApp(
        builder: FlutterSmartDialog.init(),
        home: const Scaffold(body: Text('fixture'))));
    final request = RecordingSender();
    final controller = FixtureSenderController(
        client: SyncClinet(
            id: 'tv',
            name: 'tv',
            address: '127.0.0.1',
            port: 23234,
            type: 'tv'),
        info: SyncClientInfoModel(
            name: 'tv',
            version: '1',
            address: '127.0.0.1',
            port: 23234,
            type: 'tv'))
      ..request = request;
    await controller.syncFollowAndTag();
    expect(request.follows, 1);
    expect(request.tags, 0);
    SmartDialog.dismiss(status: SmartStatus.allToast);
    await tester.pumpAndSettle();
  });

  test('device discovery ignores malformed packets and decodes UTF-8 names',
      () {
    final service = SyncService();
    for (final bytes in [
      [255, 254],
      utf8.encode('{broken'),
      utf8.encode('{"type":17}')
    ]) {
      service.listenUdp(Datagram(
          Uint8List.fromList(bytes), InternetAddress.loopbackIPv4, 23235));
    }
    service.listenUdp(Datagram(
        Uint8List.fromList(utf8.encode(jsonEncode({
          'id': 'fixture',
          'name': '客厅电视',
          'type': 'tv',
        }))),
        InternetAddress.loopbackIPv4,
        23235));
    expect(service.scanClients.single.name, '客厅电视');
    service.onClose();
  });
}
