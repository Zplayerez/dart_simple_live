import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_account/simple_live_account.dart';

void main() {
  final now = DateTime.utc(2026, 10, 2, 12);
  const cookie = 'SESSDATA=synthetic-pairing-secret; DedeUserID=42';
  AccountPairingReceiver receiver() => AccountPairingReceiver.create(
    receiverUri: Uri.parse('http://192.168.1.42:18800'),
    siteId: 'bilibili',
    now: now,
  );

  test(
    'encrypted acknowledgement authenticates exact receiver and send',
    () async {
      final target = receiver();
      final invitation = AccountPairingInvitation.parse(
        target.qrPayload,
        now: now,
      );
      final request = await invitation.encryptCookie(cookie, now: now);
      await target.decrypt(request, now: now);
      final reply = await target.encryptReply({
        'status': true,
        'message': '已保存',
      });
      expect(await invitation.decryptReply(reply), {
        'status': true,
        'message': '已保存',
      });
      expect(reply, isNot(contains(cookie)));
      await expectLater(
        invitation.decryptReply('{"status":true,"message":"forged"}'),
        throwsFormatException,
      );
      final altered = jsonDecode(reply) as Map<String, dynamic>;
      final bytes = base64Url.decode(altered['ciphertext'] as String);
      bytes[0] ^= 1;
      altered['ciphertext'] = base64Url.encode(bytes);
      await expectLater(
        invitation.decryptReply(jsonEncode(altered)),
        throwsFormatException,
      );
      final other = receiver().invitation;
      await other.encryptCookie(cookie, now: now);
      await expectLater(other.decryptReply(reply), throwsFormatException);
      // A replayed acknowledgement cannot confirm a later send with a new nonce.
      await invitation.encryptCookie('SESSDATA=synthetic-other', now: now);
      await expectLater(invitation.decryptReply(reply), throwsFormatException);
    },
  );

  test(
    'acknowledgement requires authenticated request and excludes credentials',
    () async {
      final target = receiver();
      await expectLater(
        target.encryptReply({'status': true, 'message': 'too early'}),
        throwsStateError,
      );
      final request = await target.invitation.encryptCookie(cookie, now: now);
      await target.decrypt(request, now: now);
      await expectLater(
        target.encryptReply({
          'status': true,
          'message': 'saved',
          'cookie': cookie,
        }),
        throwsFormatException,
      );
      final longMessage = List.filled(4096, 'x').join();
      await expectLater(
        target.encryptReply({'status': true, 'message': longMessage}),
        throwsFormatException,
      );
    },
  );

  test(
    'authenticated round trip exposes no Cookie in QR or wire payload',
    () async {
      final target = receiver();
      final invitation = AccountPairingInvitation.parse(
        target.qrPayload,
        now: now,
      );
      expect(invitation.receiverUri.path, '/account-pairing');
      final payload = await invitation.encryptCookie(cookie, now: now);
      for (final text in [
        target.qrPayload,
        payload,
        target.toString(),
        invitation.toString(),
      ]) {
        expect(text, isNot(contains('synthetic-pairing-secret')));
        expect(text, isNot(contains('SESSDATA')));
      }
      final key = (jsonDecode(target.qrPayload) as Map)['key'] as String;
      expect(target.toString(), isNot(contains(key)));
      expect(invitation.toString(), isNot(contains(key)));
      expect(await target.decrypt(payload, now: now), cookie);
      expect(target.isConsumed, isTrue);
      await expectLater(target.decrypt(payload, now: now), throwsStateError);
    },
  );

  test(
    'wrong key does not consume invitation and never reveals plaintext',
    () async {
      final target = receiver();
      final badQr = jsonDecode(target.qrPayload) as Map<String, dynamic>;
      badQr['key'] = base64Url.encode(List.filled(32, 0));
      final wrongKey = AccountPairingInvitation.parse(
        jsonEncode(badQr),
        now: now,
      );
      await expectLater(
        target.decrypt(
          await wrongKey.encryptCookie(cookie, now: now),
          now: now,
        ),
        throwsFormatException,
      );
      expect(target.isConsumed, isFalse);
      final invitation = AccountPairingInvitation.parse(
        target.qrPayload,
        now: now,
      );
      expect(
        await target.decrypt(
          await invitation.encryptCookie(cookie, now: now),
          now: now,
        ),
        cookie,
      );
    },
  );

  test(
    'id and selected platform must match authenticated invitation',
    () async {
      final target = receiver();
      final invitation = AccountPairingInvitation.parse(
        target.qrPayload,
        now: now,
      );
      final payload = await invitation.encryptCookie(cookie, now: now);
      for (final field in ['id', 'site']) {
        final tampered = jsonDecode(payload) as Map<String, dynamic>;
        tampered[field] = field == 'site' ? 'douyu' : 'another-invitation';
        await expectLater(
          target.decrypt(jsonEncode(tampered), now: now),
          throwsFormatException,
        );
        expect(target.isConsumed, isFalse);
      }
      expect(await target.decrypt(payload, now: now), cookie);
    },
  );

  test(
    'receiver endpoint is bound to encrypted payload as associated data',
    () async {
      final target = receiver();
      final changed = jsonDecode(target.qrPayload) as Map<String, dynamic>;
      changed['endpoint'] = 'http://192.168.1.43:18800/account-pairing';
      final invitation = AccountPairingInvitation.parse(
        jsonEncode(changed),
        now: now,
      );
      final payload = await invitation.encryptCookie(cookie, now: now);
      await expectLater(
        target.decrypt(payload, now: now),
        throwsFormatException,
      );
      expect(target.isConsumed, isFalse);
    },
  );

  test(
    'expiry is enforced by invitation parser, sender and receiver',
    () async {
      final target = receiver();
      final invitation = AccountPairingInvitation.parse(
        target.qrPayload,
        now: now,
      );
      final payload = await invitation.encryptCookie(cookie, now: now);
      final expiry = now.add(accountPairingLifetime);
      expect(
        () => AccountPairingInvitation.parse(target.qrPayload, now: expiry),
        throwsFormatException,
      );
      await expectLater(
        invitation.encryptCookie(cookie, now: expiry),
        throwsStateError,
      );
      await expectLater(target.decrypt(payload, now: expiry), throwsStateError);
      expect(target.isConsumed, isFalse);
    },
  );

  test('closing receiver immediately rejects future submissions', () async {
    final target = receiver();
    final payload = await target.invitation.encryptCookie(cookie, now: now);
    target.close();
    await expectLater(target.decrypt(payload, now: now), throwsStateError);
    expect(target.isClosed, isTrue);
  });

  test(
    'parallel submissions cannot decrypt the same invitation twice',
    () async {
      final target = receiver();
      final payload = await target.invitation.encryptCookie(cookie, now: now);
      final first = target.decrypt(payload, now: now);
      await expectLater(target.decrypt(payload, now: now), throwsStateError);
      expect(await first, cookie);
      expect(target.isConsumed, isTrue);
    },
  );

  test('only literal local IP endpoints at the pairing path are accepted', () {
    for (final uri in [
      'http://10.0.0.1:1234',
      'http://172.16.0.1:1234',
      'http://192.168.1.1:1234',
      'http://127.0.0.1:1234',
      'http://[::1]:1234',
      'http://[fd00::1]:1234',
    ]) {
      expect(
        AccountPairingReceiver.create(
          receiverUri: Uri.parse(uri),
          siteId: 'douyu',
          now: now,
        ).invitation.siteId,
        'douyu',
      );
    }
    for (final uri in [
      'http://example.com:1234',
      'http://localhost:1234',
      'http://8.8.8.8:1234',
      'https://192.168.1.1:1234',
      'http://0.0.0.0:1234',
      'http://224.0.0.1:1234',
      'http://192.168.1.1:1234/other',
      'http://192.168.1.1:1234/?key=secret',
      'http://user:pass@192.168.1.1:1234',
      'http://192.168.1.1:1234/#x',
    ]) {
      expect(
        () => AccountPairingReceiver.create(
          receiverUri: Uri.parse(uri),
          siteId: 'douyu',
          now: now,
        ),
        throwsFormatException,
      );
    }
  });

  test(
    'payload and Cookie bounds prevent unlimited allocations or transfer',
    () async {
      final target = receiver();
      final oversized = List.filled(
        accountPairingMaxPayloadBytes + 1,
        'x',
      ).join();
      await expectLater(
        target.decrypt(oversized, now: now),
        throwsFormatException,
      );
      expect(target.isConsumed, isFalse);
      final oversizedCookie =
          'a=${List.filled(accountPairingMaxCookieBytes, 'x').join()}';
      await expectLater(
        target.invitation.encryptCookie(oversizedCookie, now: now),
        throwsFormatException,
      );
      expect(
        () => AccountPairingInvitation.parse(oversized, now: now),
        throwsFormatException,
      );
    },
  );

  test(
    'tampered ciphertext is rejected before consuming the invitation',
    () async {
      final target = receiver();
      final payload =
          jsonDecode(await target.invitation.encryptCookie(cookie, now: now))
              as Map<String, dynamic>;
      final bytes = base64Url.decode(payload['ciphertext'] as String);
      bytes[0] ^= 1;
      payload['ciphertext'] = base64Url.encode(bytes);
      await expectLater(
        target.decrypt(jsonEncode(payload), now: now),
        throwsFormatException,
      );
      expect(target.isConsumed, isFalse);
    },
  );

  test('random invitations and encryption nonces differ', () async {
    final first = receiver();
    final second = receiver();
    expect(first.invitation.id, isNot(second.invitation.id));
    expect(first.qrPayload, isNot(second.qrPayload));
    final a =
        jsonDecode(await first.invitation.encryptCookie(cookie, now: now))
            as Map;
    final b =
        jsonDecode(await first.invitation.encryptCookie(cookie, now: now))
            as Map;
    expect(a['nonce'], isNot(b['nonce']));
  });
}
