import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:signalr_netcore/hub_connection.dart';
import 'package:simple_live_app/modules/sync/local_sync/local_sync_address.dart';
import 'package:simple_live_app/modules/sync/remote_sync/room/remote_sync_room_controller.dart';
import 'package:simple_live_app/modules/sync/remote_sync/room/remote_sync_room_page.dart';
import 'package:simple_live_app/services/signalr_service.dart';

class FixtureHub implements HubConnection {
  ClosedCallback? closed;
  Object? response;
  Exception? failure;
  Completer<Object?>? pending;
  final handlers = <String, MethodInvocationFunc>{};
  @override
  Future<void> start() async {}
  @override
  Future<void> stop() async => closed?.call();
  @override
  void onclose(ClosedCallback callback) => closed = callback;
  @override
  void on(String methodName, MethodInvocationFunc newMethod) =>
      handlers[methodName] = newMethod;
  @override
  Future<Object?> invoke(String methodName, {List<Object>? args}) async {
    if (failure != null) throw failure!;
    return pending == null ? response : pending!.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  tearDown(() => Get.reset());

  test('legacy multi-interface QR and custom port are preserved', () {
    final endpoints =
        parseLocalSyncAddresses('192.168.1.10; 10.0.0.2:23456;192.168.1.10');
    expect(endpoints.map((e) => e.host), ['192.168.1.10', '10.0.0.2']);
    expect(endpoints.map((e) => e.port), [23234, 23456]);
    expect(
        parseLocalSyncAddresses('http://192.168.1.10:4567/').single.port, 4567);
    expect(parseLocalSyncAddresses('fe80::1').single.host, 'fe80::1');
    for (final input in [
      '',
      'https://example.invalid/login',
      '192.168.1.2?token=secret',
      'user@192.168.1.2',
      '192.168.1.2:99999',
      '192.168.1.2/sync/follow'
    ]) {
      expect(() => parseLocalSyncAddresses(input), throwsFormatException);
    }
  });

  test('server invocation error is distinguishable from a network failure',
      () async {
    final hub = FixtureHub()
      ..failure = Exception(
          "An unexpected error occurred invoking 'CreateRoom' on the server.");
    final service =
        SignalRService(connectionFactory: (_) => hub, appVersion: 'fixture');
    await service.connect();
    await expectLater(
        service.createRoom(),
        throwsA(isA<RemoteSyncException>()
            .having((e) => e.message, 'message', contains('服务器内部错误'))));
    service.dispose();
    await pumpEventQueue();
  });

  test('requests time out and missing room IDs are rejected', () async {
    final hub = FixtureHub()..pending = Completer<Object?>();
    final service = SignalRService(
        connectionFactory: (_) => hub,
        appVersion: 'fixture',
        requestTimeout: const Duration(milliseconds: 20));
    await service.connect();
    await expectLater(
        service.createRoom(),
        throwsA(isA<RemoteSyncException>()
            .having((e) => e.message, 'message', contains('超时'))));
    hub.pending!.complete(null);
    hub.pending = null;
    hub.response = {'isSuccess': true, 'data': null};
    await expectLater(
        service.createRoom(), throwsA(isA<RemoteSyncException>()));
    service.dispose();
    await pumpEventQueue();
  });

  test('closed and superseded connections cannot write to event streams',
      () async {
    final first = FixtureHub();
    final second = FixtureHub();
    var attempt = 0;
    final service = SignalRService(
        connectionFactory: (_) => attempt++ == 0 ? first : second);
    final received = <(bool, String)>[];
    final sub = service.onFavoriteStream.listen(received.add);
    await service.connect();
    await service.connect();
    first.handlers['onFavoriteReceived']!([false, 'old']);
    second.handlers['onFavoriteReceived']!([false, 'current']);
    await pumpEventQueue();
    expect(received, [(false, 'current')]);
    service.dispose();
    second.handlers['onFavoriteReceived']!([false, 'late']);
    await pumpEventQueue();
    await sub.cancel();
  });

  testWidgets('creation failure keeps the page open with retry and LAN entry',
      (tester) async {
    Get.testMode = true;
    final hub = FixtureHub()
      ..failure = Exception(
          "An unexpected error occurred invoking 'CreateRoom' on the server.");
    final service =
        SignalRService(connectionFactory: (_) => hub, appVersion: 'fixture');
    final controller = Get.put(RemoteSyncRoomController('', service: service));
    await tester.pumpWidget(const GetMaterialApp(home: RemoteSyncRoomPage()));
    await tester.pumpAndSettle();
    expect(find.textContaining('服务器内部错误'), findsOneWidget);
    expect(find.text('使用局域网同步'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
    expect(controller.ready.value, isFalse);
    hub.failure = null;
    hub.response = {'isSuccess': true, 'message': '', 'data': 'ABCDE'};
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.text('ABCDE'), findsOneWidget);
    expect(controller.ready.value, isTrue);
    await Get.delete<RemoteSyncRoomController>();
    await tester.pumpWidget(const SizedBox());
  });
}
