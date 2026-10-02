import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_account/simple_live_account.dart';
import 'package:simple_live_core/simple_live_core.dart';

class MemoryCredentialStore implements CredentialStore {
  final values = <String, String>{};
  bool failWrites = false;
  bool failReads = false;
  bool failDeletes = false;
  bool discardWrites = false;
  Completer<void>? writeGate;
  final writeStarted = Completer<void>();

  @override
  Future<String?> read(String siteId) async {
    if (failReads) throw StateError('Synthetic storage failure');
    return values[siteId];
  }

  @override
  Future<void> write(String siteId, String cookie) async {
    if (!writeStarted.isCompleted) writeStarted.complete();
    await writeGate?.future;
    if (failWrites) throw StateError('Synthetic storage failure');
    if (!discardWrites) values[siteId] = cookie;
  }

  @override
  Future<void> delete(String siteId) async {
    if (failDeletes) throw StateError('Synthetic storage failure');
    values.remove(siteId);
  }
}

Future<LiveAccountValidation> configured(LiveAccountSession session) async =>
    const LiveAccountValidation(
      status: LiveAccountStatus.configured,
      message: 'Account identity has not been verified',
    );

PlatformAccountManager managerWith(
  MemoryCredentialStore store, {
  AccountVerifier verifier = configured,
  LegacyCredentialReader? readLegacy,
  LegacyCredentialRemover? removeLegacy,
  Future<bool> Function(String)? readBlocked,
  Future<void> Function(String, bool)? writeBlocked,
  AccountCookieCleanup? cleanup,
}) => PlatformAccountManager(
  sites: {
    'bilibili': LiveSite(id: 'bilibili'),
    'douyu': LiveSite(id: 'douyu'),
    'huya': LiveSite(id: 'huya'),
    'douyin': LiveSite(id: 'douyin'),
  },
  store: store,
  verifier: verifier,
  readLegacyCredential: readLegacy,
  removeLegacyCredential: removeLegacy,
  readRestoreBlocked: readBlocked,
  writeRestoreBlocked: writeBlocked,
  clearWebCookies: cleanup,
);

void main() {
  test(
    'verification of a rotated token supersedes an old expiry response',
    () async {
      final store = MemoryCredentialStore();
      final site = LiveSite(id: 'bilibili');
      final delayed = Completer<LiveAccountValidation>();
      final manager = PlatformAccountManager(
        sites: {'bilibili': site},
        store: store,
        verifier: (session) async {
          if (session.cookie.header == 'SESSDATA=synthetic-old')
            return delayed.future;
          return const LiveAccountValidation(
            status: LiveAccountStatus.verified,
            message: 'Fresh token verified',
            userId: '42',
          );
        },
      );
      await manager.importCookie(
        'bilibili',
        'SESSDATA=synthetic-old',
        verify: false,
      );
      final verification = manager.verify('bilibili');
      site
          .accountRequestHeaders(manager.sessionFor('bilibili'), {})
          .acceptResponseCookies(Uri.parse('https://www.bilibili.com/'), [
            'SESSDATA=synthetic-new; Domain=.bilibili.com; Path=/; Secure',
          ]);
      delayed.complete(
        const LiveAccountValidation(
          status: LiveAccountStatus.expired,
          message: 'Old token expired',
        ),
      );
      await verification;
      await pumpEventQueue();
      expect(manager.account('bilibili').status, LiveAccountStatus.verified);
      expect(manager.account('bilibili').userId, '42');
      expect(manager.account('bilibili').revision, 1);
      expect(store.values['bilibili'], 'SESSDATA=synthetic-new');
    },
  );

  test(
    'server clearing all cookies expires identity and rejects older verification',
    () async {
      final store = MemoryCredentialStore();
      final site = LiveSite(id: 'bilibili');
      final delayed = Completer<LiveAccountValidation>();
      final manager = PlatformAccountManager(
        sites: {'bilibili': site},
        store: store,
        verifier: (_) => delayed.future,
      );
      await manager.importCookie(
        'bilibili',
        'SESSDATA=synthetic-old',
        verify: false,
      );
      final verification = manager.verify('bilibili');
      site
          .accountRequestHeaders(manager.sessionFor('bilibili'), {})
          .acceptResponseCookies(Uri.parse('https://www.bilibili.com/'), [
            'SESSDATA=; Domain=.bilibili.com; Path=/; Max-Age=0; Secure',
          ]);
      delayed.complete(
        const LiveAccountValidation(
          status: LiveAccountStatus.verified,
          message: 'Stale verification',
          userId: '42',
        ),
      );
      await verification;
      await pumpEventQueue();
      expect(manager.account('bilibili').status, LiveAccountStatus.expired);
      expect(manager.account('bilibili').hasCredential, isFalse);
      expect(manager.account('bilibili').userId, isNull);
      expect(manager.account('bilibili').revision, 1);
      expect(store.values['bilibili'], '');
      final restarted = managerWith(
        store,
        readLegacy: (id) async =>
            id == 'bilibili' ? 'SESSDATA=synthetic-stale-legacy' : null,
      );
      await restarted.initialize();
      expect(restarted.sessionFor('bilibili'), isNull);
    },
  );

  test(
    'server cookie renewal persists without changing account revision',
    () async {
      final store = MemoryCredentialStore();
      final site = LiveSite(id: 'douyu');
      final manager = PlatformAccountManager(
        sites: {'douyu': site},
        store: store,
        verifier: configured,
      );
      await manager.importCookie(
        'douyu',
        'acf_auth=synthetic-old',
        verify: false,
      );
      final headers = site.accountRequestHeaders(
        manager.sessionFor('douyu'),
        {},
      );
      headers.acceptResponseCookies(Uri.parse('https://www.douyu.com/'), [
        'acf_auth=synthetic-rotated; Domain=.douyu.com; Path=/; Secure',
      ]);
      await pumpEventQueue();
      expect(manager.credentialFor('douyu'), 'acf_auth=synthetic-rotated');
      expect(store.values['douyu'], 'acf_auth=synthetic-rotated');
      expect(manager.account('douyu').revision, 1);
      expect(manager.account('douyu').status, LiveAccountStatus.configured);
    },
  );

  test('old response cookies cannot revive a logged-out account', () async {
    final store = MemoryCredentialStore();
    final site = LiveSite(id: 'douyu');
    final manager = PlatformAccountManager(
      sites: {'douyu': site},
      store: store,
      verifier: configured,
    );
    await manager.importCookie(
      'douyu',
      'acf_auth=synthetic-old',
      verify: false,
    );
    final headers = site.accountRequestHeaders(manager.sessionFor('douyu'), {});
    await manager.logout('douyu');
    headers.acceptResponseCookies(Uri.parse('https://www.douyu.com/'), [
      'acf_auth=synthetic-late; Domain=.douyu.com; Path=/; Secure',
    ]);
    await pumpEventQueue();
    expect(manager.sessionFor('douyu'), isNull);
    expect(store.values, isEmpty);
    expect(manager.account('douyu').status, LiveAccountStatus.signedOut);
  });

  test(
    'migration removes old data only after secure write and readback',
    () async {
      final store = MemoryCredentialStore();
      final legacy = {'bilibili': 'SESSDATA=synthetic-old'};
      final manager = managerWith(
        store,
        readLegacy: (id) async => legacy[id],
        removeLegacy: (id) async {
          expect(store.values[id], legacy[id]);
          legacy.remove(id);
        },
      );
      await manager.initialize();
      expect(legacy, isEmpty);
      expect(
        manager.account('bilibili').persistence,
        AccountPersistence.secure,
      );
      expect(manager.account('bilibili').status, LiveAccountStatus.configured);
    },
  );

  test(
    'unavailable secure storage preserves legacy and uses memory only',
    () async {
      final store = MemoryCredentialStore()..failWrites = true;
      final legacy = {'douyin': 'synthetic-ttwid'};
      final manager = managerWith(
        store,
        readLegacy: (id) async => legacy[id],
        removeLegacy: (id) async {
          legacy.remove(id);
        },
      );
      await manager.initialize();
      expect(legacy['douyin'], 'synthetic-ttwid');
      expect(store.values, isEmpty);
      expect(manager.credentialFor('douyin'), 'ttwid=synthetic-ttwid');
      expect(
        manager.account('douyin').persistence,
        AccountPersistence.sessionOnly,
      );
      expect(manager.account('douyin').storageMessage, isNotNull);
    },
  );

  test('silent failed readback cannot delete old migration data', () async {
    final store = MemoryCredentialStore()..discardWrites = true;
    var removed = false;
    final manager = managerWith(
      store,
      readLegacy: (id) async =>
          id == 'bilibili' ? 'SESSDATA=synthetic-old' : null,
      removeLegacy: (_) async {
        removed = true;
      },
    );
    await manager.initialize();
    expect(removed, isFalse);
    expect(
      manager.account('bilibili').persistence,
      AccountPersistence.sessionOnly,
    );
  });

  test(
    'network error preserves credential and previously verified identity',
    () async {
      final store = MemoryCredentialStore();
      var calls = 0;
      final manager = managerWith(
        store,
        verifier: (_) async {
          if (++calls > 1) throw TimeoutException('Synthetic outage');
          return const LiveAccountValidation(
            status: LiveAccountStatus.verified,
            message: 'Verified',
            userId: '42',
            displayName: 'Synthetic test account',
          );
        },
      );
      await manager.importCookie('bilibili', 'SESSDATA=synthetic');
      await manager.verify('bilibili');
      expect(manager.account('bilibili').status, LiveAccountStatus.unavailable);
      expect(manager.account('bilibili').userId, '42');
      expect(manager.credentialFor('bilibili'), 'SESSDATA=synthetic');
      expect(store.values['bilibili'], 'SESSDATA=synthetic');
    },
  );

  test(
    'explicit expiry does not delete Cookie or report network failure',
    () async {
      final store = MemoryCredentialStore();
      final manager = managerWith(
        store,
        verifier: (_) async => const LiveAccountValidation(
          status: LiveAccountStatus.expired,
          message: 'Expired',
        ),
      );
      await manager.importCookie('bilibili', 'SESSDATA=synthetic');
      expect(manager.account('bilibili').status, LiveAccountStatus.expired);
      expect(manager.account('bilibili').hasCredential, isTrue);
      expect(store.values['bilibili'], 'SESSDATA=synthetic');
    },
  );

  test('late verification cannot replace a newly imported account', () async {
    final store = MemoryCredentialStore();
    final delayed = Completer<LiveAccountValidation>();
    final started = Completer<void>();
    final manager = managerWith(
      store,
      verifier: (session) async {
        if (session.cookie.header == 'SESSDATA=synthetic-old') {
          started.complete();
          return delayed.future;
        }
        return const LiveAccountValidation(
          status: LiveAccountStatus.verified,
          message: 'Verified new account',
          userId: '2',
        );
      },
    );
    final oldImport = manager.importCookie(
      'bilibili',
      'SESSDATA=synthetic-old',
    );
    await started.future;
    await manager.importCookie('bilibili', 'SESSDATA=synthetic-new');
    delayed.complete(
      const LiveAccountValidation(
        status: LiveAccountStatus.verified,
        message: 'Verified old account',
        userId: '1',
      ),
    );
    await oldImport;
    expect(manager.account('bilibili').userId, '2');
    expect(manager.account('bilibili').revision, 2);
    expect(store.values['bilibili'], 'SESSDATA=synthetic-new');
  });

  test(
    'logout invalidates pending verification and isolates platform cookies',
    () async {
      final store = MemoryCredentialStore();
      final delayed = Completer<LiveAccountValidation>();
      final started = Completer<void>();
      final cleaned = <String>[];
      final manager = managerWith(
        store,
        cleanup: (id) async {
          cleaned.add(id);
        },
        verifier: (_) {
          started.complete();
          return delayed.future;
        },
      );
      await manager.importCookie(
        'douyu',
        'acf_auth=synthetic-douyu',
        verify: false,
      );
      final pending = manager.importCookie('bilibili', 'SESSDATA=synthetic');
      await started.future;
      await manager.logout('bilibili');
      delayed.complete(
        const LiveAccountValidation(
          status: LiveAccountStatus.verified,
          message: 'Late result',
          userId: '1',
        ),
      );
      await pending;
      expect(manager.account('bilibili').status, LiveAccountStatus.signedOut);
      expect(manager.sessionFor('bilibili'), isNull);
      expect(store.values.containsKey('bilibili'), isFalse);
      expect(store.values['douyu'], 'acf_auth=synthetic-douyu');
      expect(cleaned, ['bilibili']);
    },
  );

  test('logout queues deletion after an in-flight secure write', () async {
    final store = MemoryCredentialStore()..writeGate = Completer<void>();
    final manager = managerWith(store);
    final pending = manager.importCookie(
      'bilibili',
      'SESSDATA=synthetic',
      verify: false,
    );
    await store.writeStarted.future;
    final logout = manager.logout('bilibili');
    store.writeGate!.complete();
    await Future.wait([pending, logout]);
    expect(store.values, isEmpty);
    expect(manager.account('bilibili').hasCredential, isFalse);
  });

  test(
    'latest concurrent import wins both memory and persistent storage',
    () async {
      final store = MemoryCredentialStore()..writeGate = Completer<void>();
      final manager = managerWith(store);
      final first = manager.importCookie(
        'bilibili',
        'SESSDATA=synthetic-first',
        verify: false,
      );
      await store.writeStarted.future;
      final second = manager.importCookie(
        'bilibili',
        'SESSDATA=synthetic-second',
        verify: false,
      );
      store.writeGate!.complete();
      await Future.wait([first, second]);
      expect(manager.credentialFor('bilibili'), 'SESSDATA=synthetic-second');
      expect(store.values['bilibili'], 'SESSDATA=synthetic-second');
    },
  );

  test(
    'failed deletion cannot restore account after restart with logout marker',
    () async {
      final store = MemoryCredentialStore();
      final blocked = <String, bool>{};
      PlatformAccountManager create() => managerWith(
        store,
        readBlocked: (id) async => blocked[id] ?? false,
        writeBlocked: (id, value) async {
          blocked[id] = value;
        },
      );
      final manager = create();
      await manager.importCookie(
        'bilibili',
        'SESSDATA=synthetic',
        verify: false,
      );
      store.failDeletes = true;
      await manager.logout('bilibili');
      expect(blocked['bilibili'], isTrue);
      expect(manager.account('bilibili').storageMessage, isNotNull);
      final restarted = create();
      await restarted.initialize();
      expect(restarted.sessionFor('bilibili'), isNull);
      expect(restarted.account('bilibili').status, LiveAccountStatus.signedOut);
    },
  );

  test('marker failure still attempts secure deletion', () async {
    final store = MemoryCredentialStore();
    final manager = managerWith(
      store,
      writeBlocked: (_, blocked) async {
        if (blocked) throw StateError('Synthetic metadata failure');
      },
    );
    await manager.importCookie('bilibili', 'SESSDATA=synthetic', verify: false);
    await manager.logout('bilibili');
    expect(store.values, isEmpty);
  });

  test('invalid and empty Cookie do not mutate the current account', () async {
    final manager = managerWith(MemoryCredentialStore());
    await manager.importCookie('bilibili', 'SESSDATA=synthetic', verify: false);
    for (final raw in ['', 'not-a-cookie', 'a=b\r\ninjected=header']) {
      await expectLater(
        manager.importCookie('bilibili', raw),
        throwsFormatException,
      );
    }
    expect(manager.account('bilibili').revision, 1);
    expect(manager.credentialFor('bilibili'), 'SESSDATA=synthetic');
  });

  test(
    'bare ttwid is configured and never implies verified identity',
    () async {
      final manager = managerWith(
        MemoryCredentialStore(),
        verifier: PlatformAccountValidator.validate,
      );
      await manager.importCookie('douyin', 'synthetic-device-token');
      expect(manager.account('douyin').status, LiveAccountStatus.configured);
      expect(manager.account('douyin').userId, isNull);
      expect(manager.credentialFor('douyin'), 'ttwid=synthetic-device-token');
    },
  );
}
