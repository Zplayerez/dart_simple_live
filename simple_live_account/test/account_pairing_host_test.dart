import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_account/simple_live_account.dart';
import 'package:simple_live_core/simple_live_core.dart';

class RecordingStore implements CredentialStore {
  final values = <String, String>{};
  int writes = 0;
  @override
  Future<String?> read(String siteId) async => values[siteId];
  @override
  Future<void> write(String siteId, String cookie) async {
    ++writes;
    values[siteId] = cookie;
  }

  @override
  Future<void> delete(String siteId) async {
    values.remove(siteId);
  }
}

void main() {
  late RecordingStore store;
  late PlatformAccountManager manager;
  late AccountPairingHost host;
  final address = Uri.parse('http://192.168.1.42:18800');
  const cookie = 'SESSDATA=synthetic-paired-host';

  setUp(() {
    store = RecordingStore();
    manager = PlatformAccountManager(
      sites: {'bilibili': LiveSite(id: 'bilibili')},
      store: store,
      verifier: (_) async => const LiveAccountValidation(
        status: LiveAccountStatus.configured,
        message: '已配置，尚未验证身份',
      ),
    );
    host = AccountPairingHost(manager);
  });
  tearDown(() {
    host.cancel();
  });

  test(
    'credential is imported only after confirmation and reply is authenticated',
    () async {
      final confirm = Completer<bool>();
      final asked = Completer<void>();
      final receiver = host.start(
        address,
        'bilibili',
        confirm: () {
          asked.complete();
          return confirm.future;
        },
        onStatus: (_) {},
      );
      final invitation = AccountPairingInvitation.parse(receiver.qrPayload);
      final body = await invitation.encryptCookie(cookie);
      final pending = host.receive(body);
      await asked.future;
      expect(manager.account('bilibili').hasCredential, isFalse);
      expect(store.writes, 0);
      confirm.complete(true);
      final envelope = await pending;
      expect(envelope.containsKey('status'), isFalse);
      expect(envelope['kind'], 'reply');
      expect(jsonEncode(envelope), isNot(contains(cookie)));
      final result = await invitation.decryptReply(jsonEncode(envelope));
      expect(result['status'], isTrue);
      expect(result['message'], contains('尚未验证'));
      expect(manager.credentialFor('bilibili'), cookie);
      expect(store.writes, 1);
      await expectLater(
        invitation.decryptReply('{"status":true,"message":"forged"}'),
        throwsFormatException,
      );
    },
  );

  test(
    'declining confirmation returns encrypted refusal without importing',
    () async {
      final receiver = host.start(
        address,
        'bilibili',
        confirm: () async => false,
        onStatus: (_) {},
      );
      final invitation = AccountPairingInvitation.parse(receiver.qrPayload);
      final envelope = await host.receive(
        await invitation.encryptCookie(cookie),
      );
      expect(envelope.containsKey('status'), isFalse);
      expect(
        (await invitation.decryptReply(jsonEncode(envelope)))['status'],
        isFalse,
      );
      expect(store.writes, 0);
      expect(manager.account('bilibili').hasCredential, isFalse);
    },
  );

  test(
    'cancel during confirmation finishes promptly and ignores late acceptance',
    () async {
      final confirm = Completer<bool>();
      final asked = Completer<void>();
      final receiver = host.start(
        address,
        'bilibili',
        confirm: () {
          asked.complete();
          return confirm.future;
        },
        onStatus: (_) {},
      );
      final invitation = AccountPairingInvitation.parse(receiver.qrPayload);
      final pending = host.receive(await invitation.encryptCookie(cookie));
      await asked.future;
      host.cancel();
      final envelope = await pending.timeout(const Duration(seconds: 1));
      expect(
        (await invitation.decryptReply(jsonEncode(envelope)))['status'],
        isFalse,
      );
      confirm.complete(true);
      await pumpEventQueue();
      expect(store.writes, 0);
      expect(manager.account('bilibili').hasCredential, isFalse);
    },
  );

  test(
    'duplicate request cannot open another confirmation or reimport',
    () async {
      final confirm = Completer<bool>();
      final asked = Completer<void>();
      var confirmations = 0;
      final receiver = host.start(
        address,
        'bilibili',
        confirm: () {
          ++confirmations;
          asked.complete();
          return confirm.future;
        },
        onStatus: (_) {},
      );
      final invitation = AccountPairingInvitation.parse(receiver.qrPayload);
      final body = await invitation.encryptCookie(cookie);
      final pending = host.receive(body);
      await asked.future;
      final duplicate = await host.receive(body);
      expect(duplicate['status'], isFalse);
      await expectLater(
        invitation.decryptReply(jsonEncode(duplicate)),
        throwsFormatException,
      );
      confirm.complete(true);
      expect(
        (await invitation.decryptReply(jsonEncode(await pending)))['status'],
        isTrue,
      );
      final replay = await host.receive(body);
      expect(replay['status'], isFalse);
      expect(confirmations, 1);
      expect(store.writes, 1);
    },
  );

  test(
    'regeneration isolates old cancellation and new in-flight confirmation',
    () async {
      final oldConfirm = Completer<bool>();
      final oldAsked = Completer<void>();
      final oldReceiver = host.start(
        address,
        'bilibili',
        confirm: () {
          oldAsked.complete();
          return oldConfirm.future;
        },
        onStatus: (_) {},
      );
      final oldInvitation = AccountPairingInvitation.parse(
        oldReceiver.qrPayload,
      );
      final oldPending = host.receive(
        await oldInvitation.encryptCookie(cookie),
      );
      await oldAsked.future;
      final newConfirm = Completer<bool>();
      final newAsked = Completer<void>();
      final statuses = <String>[];
      final newReceiver = host.start(
        address,
        'bilibili',
        confirm: () {
          newAsked.complete();
          return newConfirm.future;
        },
        onStatus: statuses.add,
      );
      final newInvitation = AccountPairingInvitation.parse(
        newReceiver.qrPayload,
      );
      final newBody = await newInvitation.encryptCookie(
        'SESSDATA=synthetic-new-pair',
      );
      final newPending = host.receive(newBody);
      await newAsked.future;
      oldConfirm.complete(true);
      expect(
        (await oldInvitation.decryptReply(
          jsonEncode(await oldPending),
        ))['status'],
        isFalse,
      );
      expect((await host.receive(newBody))['status'], isFalse);
      expect(store.writes, 0);
      newConfirm.complete(true);
      expect(
        (await newInvitation.decryptReply(
          jsonEncode(await newPending),
        ))['status'],
        isTrue,
      );
      expect(store.values['bilibili'], 'SESSDATA=synthetic-new-pair');
      expect(store.writes, 1);
      expect(statuses, isNot(contains('未导入账号，请重新发起配对')));
    },
  );

  test(
    'unauthenticated payload neither opens confirmation nor consumes valid QR',
    () async {
      var confirmations = 0;
      final receiver = host.start(
        address,
        'bilibili',
        confirm: () async {
          ++confirmations;
          return true;
        },
        onStatus: (_) {},
      );
      final rejected = await host.receive(
        '{"status":true,"cookie":"synthetic"}',
      );
      expect(rejected['status'], isFalse);
      expect(confirmations, 0);
      expect(receiver.isConsumed, isFalse);
      expect(store.writes, 0);
      final invitation = AccountPairingInvitation.parse(receiver.qrPayload);
      final envelope = await host.receive(
        await invitation.encryptCookie(cookie),
      );
      expect(
        (await invitation.decryptReply(jsonEncode(envelope)))['status'],
        isTrue,
      );
      expect(confirmations, 1);
    },
  );

  test(
    'failure after authentication returns an encrypted negative result',
    () async {
      final receiver = host.start(
        address,
        'bilibili',
        confirm: () async {
          throw StateError('Synthetic confirmation error');
        },
        onStatus: (_) {},
      );
      final invitation = AccountPairingInvitation.parse(receiver.qrPayload);
      final envelope = await host.receive(
        await invitation.encryptCookie(cookie),
      );
      expect(envelope['kind'], 'reply');
      expect(
        (await invitation.decryptReply(jsonEncode(envelope)))['status'],
        isFalse,
      );
      expect(store.writes, 0);
    },
  );
}
