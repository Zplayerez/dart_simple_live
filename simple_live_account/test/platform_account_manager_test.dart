import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_account/simple_live_account.dart';
import 'package:simple_live_core/simple_live_core.dart';

class MemoryCredentialStore implements CredentialStore {
  final values = <String, String>{};
  int reads = 0;
  int writes = 0;
  int deletes = 0;
  bool failWrites = false;
  bool failReads = false;
  bool failDeletes = false;
  bool discardWrites = false;
  Completer<void>? writeGate;
  final writeStarted = Completer<void>();

  @override
  Future<String?> read(String siteId) async {
    reads++;
    if (failReads) throw StateError('Synthetic storage failure');
    return values[siteId];
  }

  @override
  Future<void> write(String siteId, String cookie) async {
    writes++;
    if (!writeStarted.isCompleted) writeStarted.complete();
    await writeGate?.future;
    if (failWrites) throw StateError('Synthetic storage failure');
    if (!discardWrites) values[siteId] = cookie;
  }

  @override
  Future<void> delete(String siteId) async {
    deletes++;
    if (failDeletes) throw StateError('Synthetic storage failure');
    values.remove(siteId);
  }
}

class DelayedReadStore extends MemoryCredentialStore {
  final started = Completer<void>();
  final result = Completer<String?>();

  @override
  Future<String?> read(String siteId) {
    if (siteId == 'bilibili' && !started.isCompleted) {
      started.complete();
      return result.future;
    }
    return super.read(siteId);
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

String syntheticDouyinWebHeader() => [
  'sessionid=synthetic-session',
  'sessionid_ss=synthetic-secure-session',
  'sid_tt=synthetic-account-token',
  'ttwid=synthetic-device%7Cencoded==',
  'passport_csrf_token=synthetic-csrf',
  '__ac_nonce=synthetic-nonce',
  'preferences={"volume":0.5,"autoplay":true}',
  for (var index = 0; index < 96; index++)
    'synthetic_aux_$index=${List.filled(128, 'x').join()}',
].join('; ');

void main() {
  test(
    'relogin waits for browser cleanup and retains the new session',
    () async {
      final gate = Completer<void>();
      final started = Completer<void>();
      final store = MemoryCredentialStore();
      final manager = managerWith(
        store,
        cleanup: (_) async {
          started.complete();
          await gate.future;
        },
      );
      await manager.importCookie('bilibili', 'SESSDATA=old', verify: false);
      final logout = manager.logout('bilibili');
      await started.future;
      expect(manager.isBusy('bilibili'), isTrue);
      final login = manager.importCookie(
        'bilibili',
        'SESSDATA=new',
        verify: false,
      );
      var browserReady = false;
      final browser = manager
          .prepareWebLogin('bilibili')
          .then((_) => browserReady = true);
      await pumpEventQueue();
      expect(manager.sessionFor('bilibili'), isNull);
      expect(browserReady, isFalse);
      gate.complete();
      await Future.wait([logout, login, browser]);
      expect(manager.credentialFor('bilibili'), 'SESSDATA=new');
      expect(store.values['bilibili'], 'SESSDATA=new');
      expect(manager.isBusy('bilibili'), isFalse);
      expect(browserReady, isTrue);
    },
  );

  test(
    'removing only the authentication cookie clears verified identity',
    () async {
      final site = BiliBiliSite();
      final manager = PlatformAccountManager(
        sites: {'bilibili': site},
        store: MemoryCredentialStore(),
        verifier: (_) async => const LiveAccountValidation(
          status: LiveAccountStatus.verified,
          message: 'verified fixture',
          userId: '123',
          displayName: 'fixture',
        ),
      );
      await manager.importCookie(
        'bilibili',
        'SESSDATA=synthetic; buvid3=device',
      );
      final headers = await site.getHeader() as AccountRequestHeaders;
      headers.acceptResponseCookies(Uri.parse('https://www.bilibili.com/'), [
        'SESSDATA=; Domain=.bilibili.com; Path=/; Max-Age=0',
      ]);
      await pumpEventQueue();
      expect(manager.account('bilibili').status, LiveAccountStatus.expired);
      expect(manager.account('bilibili').displayName, isNull);
      expect(manager.credentialFor('bilibili'), 'buvid3=device');
      expect(site.userId, 0);
    },
  );

  test('startup restores secure credentials without rewriting them', () async {
    final store = MemoryCredentialStore()
      ..values.addAll({
        'bilibili': 'SESSDATA=synthetic',
        'douyu': 'acf_auth=synthetic',
        'huya': 'udb_biztoken=synthetic',
        'douyin': 'sessionid=synthetic',
      });
    var markerWrites = 0;
    final manager = managerWith(
      store,
      writeBlocked: (_, __) async {
        markerWrites++;
      },
    );
    await manager.initialize();
    for (final siteId in store.values.keys) {
      expect(manager.credentialFor(siteId), store.values[siteId]);
      expect(manager.account(siteId).persistence, AccountPersistence.secure);
      expect(manager.account(siteId).status, LiveAccountStatus.configured);
    }
    expect(store.writes, 0);
    expect(store.reads, 4);
    expect(markerWrites, 0);
  });

  test(
    'startup skips storage and browser work for logged-out accounts',
    () async {
      final store = MemoryCredentialStore()
        ..values['bilibili'] = 'SESSDATA=synthetic-residual';
      var browserStarts = 0;
      final manager = managerWith(
        store,
        readBlocked: (_) async => true,
        cleanup: (_) async {
          browserStarts++;
        },
      );
      await manager.initialize();
      expect(manager.sessionFor('bilibili'), isNull);
      expect(manager.account('bilibili').status, LiveAccountStatus.signedOut);
      expect(browserStarts, 0);
      expect(store.reads, 0);
      expect(store.writes, 0);
      expect(store.deletes, 0);
    },
  );

  test(
    'startup restores a secure account even when keychain writes fail',
    () async {
      final store = MemoryCredentialStore()
        ..values['bilibili'] = 'SESSDATA=synthetic'
        ..failWrites = true;
      var removed = false;
      final manager = managerWith(
        store,
        removeLegacy: (id) async {
          if (id == 'bilibili') removed = true;
        },
      );
      await Future.wait([manager.initialize(), manager.initialize()]);
      expect(store.reads, 4, reason: 'Initialization must only restore once.');
      expect(
        removed,
        isTrue,
        reason: 'Retry legacy cleanup after a safe read.',
      );
      expect(
        manager.account('bilibili').persistence,
        AccountPersistence.secure,
      );
      expect(manager.account('bilibili').storageMessage, isNull);
    },
  );

  for (final action in ['import', 'logout']) {
    test(
      'a delayed startup restore cannot overwrite a newer $action',
      () async {
        final store = DelayedReadStore();
        final manager = managerWith(store);
        final initialization = manager.initialize();
        await store.started.future;
        if (action == 'import') {
          await manager.importCookie(
            'bilibili',
            'SESSDATA=synthetic-new',
            verify: false,
          );
        } else {
          await manager.logout('bilibili');
        }
        store.result.complete('SESSDATA=synthetic-old');
        await initialization;
        expect(
          manager.credentialFor('bilibili'),
          action == 'import' ? 'SESSDATA=synthetic-new' : '',
        );
        expect(manager.account('bilibili').revision, 1);
      },
    );
  }

  test(
    'web login retries blocked logout cleanup before reusing browser cookies',
    () async {
      final store = MemoryCredentialStore()
        ..values['bilibili'] = 'SESSDATA=synthetic-residual';
      final pending = Completer<void>();
      var browserStarts = 0;
      var prepared = false;
      final manager = managerWith(
        store,
        readBlocked: (_) async => true,
        cleanup: (_) async {
          browserStarts++;
          await pending.future;
        },
      );
      await manager.initialize();
      expect(browserStarts, 0);
      final preparation = manager
          .prepareWebLogin('bilibili')
          .then((_) => prepared = true);
      await pumpEventQueue();
      expect(browserStarts, 1);
      expect(prepared, isFalse);
      pending.complete();
      await preparation;
      expect(store.values, isEmpty);
      expect(manager.sessionFor('bilibili'), isNull);
    },
  );

  test(
    'web login does not reuse a browser when logout cleanup fails',
    () async {
      final manager = managerWith(
        MemoryCredentialStore(),
        readBlocked: (_) async => true,
        cleanup: (_) async => throw StateError('Synthetic cleanup failure'),
      );
      await manager.initialize();
      await expectLater(manager.prepareWebLogin('bilibili'), throwsStateError);
      expect(manager.account('bilibili').status, LiveAccountStatus.signedOut);
    },
  );

  test('web login keeps existing cookies when no logout is pending', () async {
    var cleanups = 0;
    final manager = managerWith(
      MemoryCredentialStore(),
      readBlocked: (_) async => false,
      cleanup: (_) async {
        cleanups++;
      },
    );
    await manager.prepareWebLogin('bilibili');
    expect(cleanups, 0);
  });

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

  group('Douyin web credentials with the real site adapter', () {
    test(
      'long mixed header survives import and secure-store restart',
      () async {
        final header = syntheticDouyinWebHeader();
        expect(header.length, greaterThan(8192));
        final store = MemoryCredentialStore();
        final site = DouyinSite()..headers['Cookie'] = 'synthetic-stale-cookie';
        final manager = PlatformAccountManager(
          sites: {'douyin': site},
          store: store,
        );

        final imported = await manager.importCookie('douyin', header);
        expect(imported.status, LiveAccountStatus.configured);
        expect(imported.persistence, AccountPersistence.secure);
        expect(imported.userId, isNull);
        expect(imported.hasCredential, isTrue);
        expect(store.values['douyin'], header);
        expect(site.cookie, header);
        expect((await site.getRequestHeaders())['cookie'], header);
        expect(site.headers.containsKey('Cookie'), isFalse);

        final restoredSite = DouyinSite();
        final restarted = PlatformAccountManager(
          sites: {'douyin': restoredSite},
          store: store,
        );
        await restarted.initialize();
        await restarted.verifyAll();
        expect(restarted.credentialFor('douyin'), header);
        expect((await restoredSite.getRequestHeaders())['cookie'], header);
        expect(
          restarted.account('douyin').persistence,
          AccountPersistence.secure,
        );
        expect(
          restarted.account('douyin').status,
          LiveAccountStatus.configured,
        );
        expect(restarted.account('douyin').userId, isNull);
        expect(restarted.account('douyin').message, contains('尚未确认'));
      },
    );

    test(
      'visitor and account cookies are distinguished without verified login',
      () async {
        final site = DouyinSite();
        final manager = PlatformAccountManager(
          sites: {'douyin': site},
          store: MemoryCredentialStore(),
        );
        final visitor = await manager.importCookie(
          'douyin',
          'ttwid=synthetic-visitor',
        );
        expect(visitor.status, LiveAccountStatus.configured);
        expect(visitor.userId, isNull);
        expect(visitor.message, contains('游客设备信息'));
        expect(site.accountSession!.cookie.hasAccountSession, isFalse);

        final account = await manager.importCookie(
          'douyin',
          'ttwid=synthetic-device; sessionid=synthetic-session',
        );
        expect(account.status, LiveAccountStatus.configured);
        expect(account.userId, isNull);
        expect(account.message, contains('账号身份与可用画质尚未确认'));
        expect(site.accountSession!.cookie.hasAccountSession, isTrue);
      },
    );

    for (final failReadback in [false, true]) {
      test(
        'long header still imports when secure ${failReadback ? 'readback' : 'write'} fails',
        () async {
          final store = MemoryCredentialStore()
            ..failWrites = !failReadback
            ..failReads = failReadback;
          final site = DouyinSite();
          final manager = PlatformAccountManager(
            sites: {'douyin': site},
            store: store,
          );
          final header = syntheticDouyinWebHeader();

          final result = await manager.importCookie('douyin', header);
          expect(result.status, LiveAccountStatus.configured);
          expect(result.persistence, AccountPersistence.sessionOnly);
          expect(result.storageMessage, contains('仅本次会话有效'));
          expect(result.hasCredential, isTrue);
          expect(result.userId, isNull);
          expect(manager.credentialFor('douyin'), header);
          expect((await site.getRequestHeaders())['cookie'], header);
        },
      );
    }
  });
}
