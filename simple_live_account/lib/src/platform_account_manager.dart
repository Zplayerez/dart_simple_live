import 'dart:async';

import 'package:get/get.dart';
import 'package:simple_live_core/simple_live_core.dart';

import 'account_state.dart';
import 'credential_store.dart';

typedef AccountVerifier =
    Future<LiveAccountValidation> Function(LiveAccountSession session);
typedef LegacyCredentialReader = Future<String?> Function(String siteId);
typedef LegacyCredentialRemover = Future<void> Function(String siteId);
typedef AccountCookieCleanup = Future<void> Function(String siteId);

class PlatformAccountManager extends GetxService {
  PlatformAccountManager({
    required Map<String, LiveSite> sites,
    CredentialStore? store,
    AccountVerifier? verifier,
    this.readLegacyCredential,
    this.removeLegacyCredential,
    this.clearWebCookies,
    this.readRestoreBlocked,
    this.writeRestoreBlocked,
  }) : _sites = Map.unmodifiable(sites),
       _store = store ?? SystemCredentialStore(),
       _verifier = verifier ?? PlatformAccountValidator.validate {
    for (final siteId in _sites.keys) {
      _platformFor(siteId);
      accounts[siteId] = PlatformAccountState(siteId: siteId);
      _sites[siteId]!.onAccountSessionUpdated = (session) {
        _acceptResponseCookie(siteId, session);
      };
    }
  }

  static PlatformAccountManager get instance => Get.find();

  final Map<String, LiveSite> _sites;
  final CredentialStore _store;
  final AccountVerifier _verifier;
  final LegacyCredentialReader? readLegacyCredential;
  final LegacyCredentialRemover? removeLegacyCredential;
  final AccountCookieCleanup? clearWebCookies;

  /// Non-secret logout markers prevent a failed keychain deletion from silently
  /// restoring an account on restart. Clients persist these booleans in Hive.
  final Future<bool> Function(String siteId)? readRestoreBlocked;
  final Future<void> Function(String siteId, bool blocked)? writeRestoreBlocked;

  final accounts = <String, PlatformAccountState>{}.obs;
  final Map<String, LiveAccountSession> _sessions = {};
  final Map<String, Future<void>> _storeTasks = {};
  final Map<String, int> _verificationAttempts = {};
  final cleaningAccounts = <String>{}.obs;
  final Map<String, Future<PlatformAccountState>> _logoutTasks = {};
  bool isBusy(String siteId) =>
      cleaningAccounts.contains(siteId) ||
      account(siteId).status == LiveAccountStatus.verifying;
  Future<void>? _initialization;

  PlatformAccountState account(String siteId) {
    final state = accounts[siteId];
    if (state == null) throw ArgumentError('Unsupported account platform');
    return state;
  }

  LiveAccountSession? sessionFor(String siteId) => _sessions[siteId];

  /// Compatibility boundary for existing login and account-sync consumers.
  /// Never include its return value in logs, settings or ordinary backups.
  String credentialFor(String siteId) => _sessions[siteId]?.cookie.header ?? '';

  Future<void> initialize() => _initialization ??= _initialize();

  Future<void> _initialize() async {
    await Future.wait(_sites.keys.map(_restore));
  }

  Future<void> verifyAll() async {
    await Future.wait(_sites.keys.map(verify));
  }

  Future<void> _restore(String siteId) async {
    final revision = account(siteId).revision;
    if (revision != 0) return;
    try {
      if (await readRestoreBlocked?.call(siteId) == true) {
        // Keep the logout tombstone without reopening the browser on every
        // launch. Cleanup is retried before an explicit web login or logout.
        return;
      }
    } catch (_) {
      // A failed safety-marker read must not accidentally restore credentials.
      if (!_isCurrent(siteId, revision)) return;
      accounts[siteId] = account(
        siteId,
      ).copyWith(storageMessage: '无法读取账号恢复设置，请重新导入凭据');
      return;
    }
    if (!_isCurrent(siteId, revision)) return;

    String? secureCookie;
    bool readable = true;
    try {
      secureCookie = await _store.read(siteId);
    } catch (_) {
      readable = false;
    }
    String? legacyCookie;
    if (secureCookie == null) {
      try {
        legacyCookie = await readLegacyCredential?.call(siteId);
      } catch (_) {
        // Keep the original migration source intact for the next launch.
      }
    }
    if (!_isCurrent(siteId, revision)) return;
    final raw = secureCookie ?? legacyCookie;
    if (raw == null || raw.isEmpty) {
      if (!readable) {
        accounts[siteId] = account(
          siteId,
        ).copyWith(storageMessage: '系统安全存储不可用，新凭据将仅在本次会话使用');
      }
      return;
    }
    try {
      if (secureCookie == null) {
        // Only a legacy migration needs a secure write and readback.
        await importCookie(siteId, raw, verify: false);
      } else {
        final cookie = PlatformCookie.parse(
          raw,
          allowBareTtwid: siteId == 'douyin',
        );
        if (cookie.isEmpty) throw const FormatException('Empty stored Cookie');
        final session = _useCookie(
          siteId,
          cookie,
          persistence: AccountPersistence.secure,
        );
        // A previous migration may have saved securely but failed to remove
        // its legacy source. Retrying that removal needs no keychain rewrite.
        await _serializeStore(siteId, () => _removeLegacy(siteId, session));
      }
    } on FormatException {
      accounts[siteId] = account(
        siteId,
      ).copyWith(storageMessage: '已有凭据格式无法识别，原数据已保留，请重新导入');
    }
  }

  Future<PlatformAccountState> importCookie(
    String siteId,
    String raw, {
    bool verify = true,
  }) async {
    final parsed = PlatformCookie.parse(
      raw,
      allowBareTtwid: siteId == 'douyin',
    );
    if (parsed.isEmpty) throw const FormatException('请输入 Cookie');
    final cleanup = _logoutTasks[siteId];
    if (cleanup != null) await cleanup;
    final session = _useCookie(siteId, parsed);

    await _persistSession(siteId, session);
    if (verify && _isCurrent(siteId, session.version)) {
      return this.verify(siteId);
    }
    return account(siteId);
  }

  LiveAccountSession _useCookie(
    String siteId,
    PlatformCookie cookie, {
    AccountPersistence persistence = AccountPersistence.sessionOnly,
  }) {
    final revision = account(siteId).revision + 1;
    final session = LiveAccountSession(
      platform: _platformFor(siteId),
      cookie: cookie,
      version: revision,
    );
    _verificationAttempts[siteId] = (_verificationAttempts[siteId] ?? 0) + 1;
    _sessions[siteId] = session;
    _sites[siteId]!.accountSession = session;
    accounts[siteId] = PlatformAccountState(
      siteId: siteId,
      status: LiveAccountStatus.configured,
      persistence: persistence,
      message: '已保存登录信息，等待验证',
      storageMessage: persistence == AccountPersistence.secure
          ? null
          : '正在保存到系统安全存储',
      revision: revision,
      hasCredential: true,
    );

    return session;
  }

  void _acceptResponseCookie(String siteId, LiveAccountSession session) {
    final current = _sessions[siteId];
    if (current == null ||
        current.version != session.version ||
        current.platform != session.platform ||
        current.cookie.header == session.cookie.header)
      return;
    _sessions[siteId] = session;
    // Server renewal retains the same revision and never restarts playback.
    if (session.cookie.isEmpty ||
        (current.cookie.hasAccountSessionFor(current.platform) &&
            !session.cookie.hasAccountSessionFor(session.platform))) {
      _verificationAttempts[siteId] = (_verificationAttempts[siteId] ?? 0) + 1;
      accounts[siteId] = account(siteId).copyWith(
        status: LiveAccountStatus.expired,
        message: '登录已失效，请重新登录；设备信息已保留',
        clearIdentity: true,
        hasCredential: !session.cookie.isEmpty,
      );
      final site = _sites[siteId];
      if (site is BiliBiliSite) site.userId = 0;
    } else if (account(siteId).status == LiveAccountStatus.verifying) {
      // A response for the pre-rotation token cannot decide whether the new
      // token is valid. Recheck the new snapshot without changing playback.
      unawaited(verify(siteId));
    }
    unawaited(_persistSession(siteId, session));
  }

  bool _isCurrentSession(String siteId, LiveAccountSession session) =>
      identical(_sessions[siteId], session);

  Future<void> _persistSession(String siteId, LiveAccountSession session) {
    return _serializeStore(siteId, () async {
      if (!_isCurrentSession(siteId, session)) return;
      try {
        await _store.write(siteId, session.cookie.header);
        // A successful write call alone does not establish a safe migration.
        if (await _store.read(siteId) != session.cookie.header) {
          throw StateError('Secure credential readback failed');
        }
        await writeRestoreBlocked?.call(siteId, session.cookie.isEmpty);
        if (!_isCurrentSession(siteId, session)) return;
        accounts[siteId] = account(siteId).copyWith(
          persistence: AccountPersistence.secure,
          clearStorageMessage: true,
        );
        await _removeLegacy(siteId, session);
      } catch (_) {
        if (_isCurrentSession(siteId, session)) {
          accounts[siteId] = account(siteId).copyWith(
            persistence: AccountPersistence.sessionOnly,
            storageMessage: '系统安全存储不可用，当前凭据仅本次会话有效；原有存储数据未删除',
          );
        }
      }
    });
  }

  Future<void> _removeLegacy(String siteId, LiveAccountSession session) async {
    if (!_isCurrentSession(siteId, session)) return;
    try {
      await removeLegacyCredential?.call(siteId);
    } catch (_) {
      if (_isCurrentSession(siteId, session)) {
        accounts[siteId] = account(
          siteId,
        ).copyWith(storageMessage: '安全存储已保存，旧数据清理将在下次启动重试');
      }
    }
  }

  /// Retry a previous logout's cleanup only when the browser will be used.
  /// Never let stale browser cookies silently undo a persisted logout.
  Future<void> prepareWebLogin(String siteId) async {
    final cleanup = _logoutTasks[siteId];
    if (cleanup != null) {
      final state = await cleanup;
      if (state.storageMessage != null) {
        throw StateError('Previous account cleanup is incomplete');
      }
      return;
    }
    final revision = account(siteId).revision;
    final blocked = await readRestoreBlocked?.call(siteId) == true;
    if (!blocked || !_isCurrent(siteId, revision)) return;
    final state = await logout(siteId);
    if (state.storageMessage != null) {
      throw StateError('Previous account cleanup is incomplete');
    }
  }

  Future<PlatformAccountState> verify(String siteId) async {
    final current = account(siteId);
    final session = _sessions[siteId];
    if (session == null) return current;
    final revision = session.version;
    final attempt = (_verificationAttempts[siteId] ?? 0) + 1;
    _verificationAttempts[siteId] = attempt;
    accounts[siteId] = current.copyWith(
      status: LiveAccountStatus.verifying,
      message: '正在验证',
    );
    LiveAccountValidation result;
    try {
      result = await _verifier(session);
    } catch (_) {
      result = const LiveAccountValidation(
        status: LiveAccountStatus.unavailable,
        message: '暂时无法验证，请稍后重试',
      );
    }
    if (!_isCurrent(siteId, revision) ||
        _verificationAttempts[siteId] != attempt) {
      return account(siteId);
    }
    final expired = result.status == LiveAccountStatus.expired;
    accounts[siteId] = account(siteId).copyWith(
      status: result.status,
      message: result.message,
      displayName: result.displayName,
      avatarUrl: result.avatarUrl,
      userId: result.userId?.toString(),
      playbackCapability: result.playbackCapability,
      clearIdentity: expired,
      checkedAt: DateTime.now(),
    );
    final site = _sites[siteId];
    if (site is BiliBiliSite) {
      if (result.status == LiveAccountStatus.verified) {
        site.userId = int.tryParse(result.userId?.toString() ?? '') ?? 0;
      } else if (expired) {
        site.userId = 0;
      }
    }
    return account(siteId);
  }

  Future<PlatformAccountState> logout(String siteId) {
    final pending = _logoutTasks[siteId];
    if (pending != null) return pending;
    cleaningAccounts.add(siteId);
    final completion = Completer<PlatformAccountState>();
    _logoutTasks[siteId] = completion.future;
    _logout(siteId)
        .then(completion.complete, onError: completion.completeError)
        .whenComplete(() {
          _logoutTasks.remove(siteId);
          cleaningAccounts.remove(siteId);
        });
    return completion.future;
  }

  Future<PlatformAccountState> _logout(String siteId) async {
    final revision = account(siteId).revision + 1;
    _verificationAttempts[siteId] = (_verificationAttempts[siteId] ?? 0) + 1;
    _sessions.remove(siteId);
    _sites[siteId]!.accountSession = null;
    accounts[siteId] = PlatformAccountState(siteId: siteId, revision: revision);
    await _serializeStore(siteId, () async {
      if (!_isCurrent(siteId, revision)) return;
      bool markerFailed = false;
      try {
        await writeRestoreBlocked?.call(siteId, true);
      } catch (_) {
        markerFailed = true;
      }
      try {
        await _store.delete(siteId);
        if (await _store.read(siteId) != null) {
          throw StateError('Secure credential deletion failed');
        }
        await removeLegacyCredential?.call(siteId);
      } catch (_) {
        if (_isCurrent(siteId, revision)) {
          accounts[siteId] = account(siteId).copyWith(
            persistence: AccountPersistence.sessionOnly,
            storageMessage: markerFailed
                ? '当前会话已退出，但无法保存退出状态或清理设备凭据；重启可能恢复旧账号，请稍后重试退出'
                : '当前会话已退出；设备凭据清理未完成，请稍后重试退出',
          );
        }
      }
      if (_isCurrent(siteId, revision)) {
        try {
          await clearWebCookies?.call(siteId);
        } catch (_) {
          if (_isCurrent(siteId, revision)) {
            accounts[siteId] = account(
              siteId,
            ).copyWith(storageMessage: '账号已退出；网页登录凭据清理失败，请在官网检查登录状态');
          }
        }
      }
    });
    return account(siteId);
  }

  bool _isCurrent(String siteId, int revision) =>
      account(siteId).revision == revision;

  Future<void> _serializeStore(
    String siteId,
    Future<void> Function() operation,
  ) {
    final next = (_storeTasks[siteId] ?? Future<void>.value()).then(
      (_) => operation(),
    );
    // Keep the queue usable even if a platform adapter unexpectedly throws.
    _storeTasks[siteId] = next.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return next;
  }

  static LiveAccountPlatform _platformFor(String siteId) {
    switch (siteId) {
      case 'bilibili':
        return LiveAccountPlatform.bilibili;
      case 'douyu':
        return LiveAccountPlatform.douyu;
      case 'huya':
        return LiveAccountPlatform.huya;
      case 'douyin':
        return LiveAccountPlatform.douyin;
      default:
        throw ArgumentError('Unsupported account platform');
    }
  }
}
