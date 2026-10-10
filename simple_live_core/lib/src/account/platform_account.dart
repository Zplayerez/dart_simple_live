import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';

enum LiveAccountPlatform { bilibili, douyu, huya, douyin }

enum LiveAccountStatus {
  signedOut,
  configured,
  verifying,
  verified,
  expired,
  unavailable,
}

/// Immutable Cookie header. Values never appear in toString or parse errors.
class PlatformCookie {
  final Map<String, String> values;
  static final _namePattern = RegExp(r"^[!#$%&'*+.^_`|~0-9a-zA-Z-]+$");

  /// Header token grammar, shared with native browser-cookie import adapters.
  /// Browsers can retain auxiliary cookies that cannot form a valid header.
  static bool isValidName(String name) => _namePattern.hasMatch(name);

  PlatformCookie._(Map<String, String> values)
    : values = Map.unmodifiable(values);

  factory PlatformCookie.parse(String input, {bool allowBareTtwid = false}) {
    var value = input.trim().replaceFirst(
      RegExp(r'^cookie\s*:\s*', caseSensitive: false),
      '',
    );
    if (RegExp(r'[\x00-\x1f\x7f]').hasMatch(value)) {
      throw const FormatException('Cookie 不能包含控制字符');
    }
    if (value.isEmpty) return PlatformCookie._({});
    if (allowBareTtwid && !value.contains('=') && !value.contains(';')) {
      value = 'ttwid=$value';
    }
    final cookies = <String, String>{};
    for (final part in value.split(';')) {
      final item = part.trim();
      if (item.isEmpty) continue;
      final equal = item.indexOf('=');
      if (equal <= 0) {
        throw const FormatException('请输入完整 Cookie，格式为 name=value');
      }
      final name = item.substring(0, equal).trim();
      if (!isValidName(name)) {
        throw const FormatException('Cookie 字段名称无效');
      }
      cookies[name] = item.substring(equal + 1).trim();
    }
    return PlatformCookie._(cookies);
  }

  String get header =>
      values.entries.map((e) => '${e.key}=${e.value}').join('; ');
  bool get isEmpty => values.isEmpty;

  /// Credential presence is only a candidate, never proof of login.
  bool hasAccountSessionFor(LiveAccountPlatform platform) {
    // Huya's current Web SDK restores login when either part of this pair is
    // missing. A user ID or the separate restore cookie alone is insufficient.
    if (platform == LiveAccountPlatform.huya &&
        (values['udb_uid']?.isNotEmpty ?? false) &&
        (values['udb_biztoken']?.isNotEmpty ?? false)) {
      return true;
    }
    final candidates = switch (platform) {
      LiveAccountPlatform.bilibili => const ['SESSDATA'],
      LiveAccountPlatform.douyu => const ['acf_auth'],
      LiveAccountPlatform.douyin => const [
        'sessionid',
        'sessionid_ss',
        'sid_tt',
      ],
      LiveAccountPlatform.huya => const ['udb_l'],
    };
    return candidates.any((key) => values[key]?.isNotEmpty ?? false);
  }

  bool get hasAccountSession =>
      LiveAccountPlatform.values.any(hasAccountSessionFor);

  /// Merge only root-path cookies for this official response host. This avoids
  /// flattening a narrower Path/host scope into a cross-site Cookie header.
  PlatformCookie mergeResponseCookies(Uri uri, Iterable<String> headers) {
    if (uri.scheme != 'https' || uri.port != 443 || uri.userInfo.isNotEmpty) {
      return this;
    }
    final merged = Map<String, String>.of(values);
    for (final header in headers) {
      try {
        final parts = header.split(';');
        final cookie = PlatformCookie.parse(parts.first);
        final attributes = <String, String>{};
        for (final part in parts.skip(1)) {
          final index = part.indexOf('=');
          attributes[(index < 0 ? part : part.substring(0, index))
              .trim()
              .toLowerCase()] = index < 0
              ? ''
              : part.substring(index + 1).trim();
        }
        final domain = attributes['domain']
            ?.replaceFirst(RegExp(r'^\.'), '')
            .toLowerCase();
        // Imported headers have platform-wide scope. Only accept explicit
        // platform root-domain updates here; host-only updates need a jar.
        if (domain == null ||
            domain !=
                uri.host
                    .split('.')
                    .skip(uri.host.split('.').length - 2)
                    .join('.')) {
          continue;
        }
        if (uri.host != domain && !uri.host.endsWith('.$domain')) continue;
        if (attributes['path'] != '/') continue;
        final expiredByDate =
            !attributes.containsKey('max-age') &&
            attributes['expires'] != null &&
            _expiredCookieDate(attributes['expires']!);
        if (expiredByDate ||
            (attributes.containsKey('max-age') &&
                (int.tryParse(attributes['max-age']!) ?? 1) <= 0)) {
          for (final key in cookie.values.keys) {
            merged.remove(key);
          }
        } else {
          merged.addAll(cookie.values);
        }
      } on FormatException {
        // Invalid server cookies do not destroy the imported account.
      }
    }
    return PlatformCookie._(merged);
  }

  static bool _expiredCookieDate(String value) {
    try {
      return !HttpDate.parse(value).isAfter(DateTime.now().toUtc());
    } catch (_) {
      return false;
    }
  }

  @override
  String toString() => 'PlatformCookie(${values.length} fields, [redacted])';
}

class LiveAccountSession {
  final LiveAccountPlatform platform;
  final PlatformCookie cookie;
  final int version;

  const LiveAccountSession({
    required this.platform,
    required this.cookie,
    required this.version,
  });

  static const _hosts = {
    LiveAccountPlatform.bilibili: {
      'api.bilibili.com',
      'api.live.bilibili.com',
      'live.bilibili.com',
      'www.bilibili.com',
    },
    LiveAccountPlatform.douyu: {'www.douyu.com', 'm.douyu.com'},
    LiveAccountPlatform.huya: {'www.huya.com', 'm.huya.com'},
    LiveAccountPlatform.douyin: {'www.douyin.com', 'live.douyin.com'},
  };

  bool permits(Uri uri) {
    if (uri.scheme != 'https' || uri.port != 443 || uri.userInfo.isNotEmpty) {
      return false;
    }
    if (_hosts[platform]!.contains(uri.host.toLowerCase())) return true;
    // Additional account hosts only receive credentials at the exact
    // verification endpoint used by the platform's official web login SDK.
    return switch (platform) {
      LiveAccountPlatform.huya =>
        uri.host == 'l.huya.com' &&
            uri.path == '/udb_web/udbport2.php' &&
            uri.queryParameters['m'] == 'HuyaLogin' &&
            uri.queryParameters['do'] == 'checkLogin',
      _ => false,
    };
  }

  static bool permitsDanmakuEndpoint(LiveAccountPlatform platform, Uri uri) {
    if (uri.scheme != 'wss' ||
        (uri.hasPort && uri.port != 443) ||
        uri.userInfo.isNotEmpty) {
      return false;
    }
    return switch (platform) {
      LiveAccountPlatform.bilibili => uri.host.endsWith('.chat.bilibili.com'),
      LiveAccountPlatform.douyin => const {
        'webcast3-ws-web-lq.douyin.com',
        'webcast5-ws-web-lf.douyin.com',
      }.contains(uri.host),
      _ => false,
    };
  }

  Map<String, String> headersFor(Uri uri) =>
      permits(uri) && !cookie.isEmpty ? {'cookie': cookie.header} : {};

  String? get deviceId {
    for (final key in const ['acf_did', 'dy_did']) {
      final value = cookie.values[key];
      if (value != null && value.isNotEmpty) return value;
    }
    return null;
  }

  @override
  String toString() =>
      'LiveAccountSession(${platform.name}, version: $version, [redacted])';
}

class LiveAccountValidation {
  final LiveAccountStatus status;
  final String message;
  final String? userId;
  final String? displayName;
  final String? avatarUrl;
  final String? playbackCapability;

  const LiveAccountValidation({
    required this.status,
    required this.message,
    this.userId,
    this.displayName,
    this.avatarUrl,
    this.playbackCapability,
  });
}

class PlatformAccountValidator {
  static const _userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36';

  static Future<LiveAccountValidation> validate(
    LiveAccountSession session, {
    Dio? dio,
  }) async {
    if (session.cookie.isEmpty) {
      return const LiveAccountValidation(
        status: LiveAccountStatus.signedOut,
        message: '未配置账号',
      );
    }
    if (!session.cookie.hasAccountSessionFor(session.platform)) {
      return LiveAccountValidation(
        status: LiveAccountStatus.signedOut,
        message: session.platform == LiveAccountPlatform.douyin
            ? '仅保存了游客设备信息，请通过网页登录并点击“完成登录”'
            : '未获取到账号登录凭据，请重新网页登录并点击“完成登录”',
      );
    }
    final client =
        dio ??
        Dio(
          BaseOptions(
            connectTimeout: const Duration(seconds: 15),
            receiveTimeout: const Duration(seconds: 15),
          ),
        );
    try {
      return await switch (session.platform) {
        LiveAccountPlatform.bilibili => _bilibili(client, session),
        LiveAccountPlatform.douyu => _douyu(client, session),
        LiveAccountPlatform.huya => _huya(client, session),
        LiveAccountPlatform.douyin => _douyin(client, session),
      };
    } catch (_) {
      return const LiveAccountValidation(
        status: LiveAccountStatus.unavailable,
        message: '验证请求未成功，请检查网络后点击“重新验证”；登录信息已保留',
      );
    } finally {
      if (dio == null) client.close();
    }
  }

  static Future<Map> _get(
    Dio client,
    LiveAccountSession session,
    Uri uri,
    String referer,
  ) async {
    if (!session.permits(uri)) throw StateError('不支持的账号验证地址');
    final response = await client.getUri(
      uri,
      options: Options(
        headers: {
          ...session.headersFor(uri),
          'user-agent': _userAgent,
          'referer': referer,
          'accept': 'application/json',
        },
        followRedirects: false,
        validateStatus: (status) => status == 200,
      ),
    );
    // Check explicitly as injected adapters can bypass Dio's validateStatus.
    if (response.statusCode != 200) throw StateError('账号验证请求失败');
    dynamic body = response.data;
    if (body is String) body = jsonDecode(body);
    if (body is! Map) throw const FormatException('账号验证响应格式异常');
    return body;
  }

  static int? _code(dynamic value) => value is int
      ? value
      : value is String
      ? int.tryParse(value)
      : null;

  static String? _userId(dynamic value) {
    final number = _code(value);
    return number != null && number > 0 ? number.toString() : null;
  }

  static String? _text(dynamic value) =>
      value is String && value.trim().isNotEmpty ? value : null;

  static LiveAccountValidation _expired(String platform) =>
      LiveAccountValidation(
        status: LiveAccountStatus.expired,
        message: '$platform已返回未登录，请重新网页登录并点击“完成登录”',
      );

  static const _unavailable = LiveAccountValidation(
    status: LiveAccountStatus.unavailable,
    message: '平台暂未返回有效验证结果，请稍后点击“重新验证”；登录信息已保留',
  );

  static Future<LiveAccountValidation> _bilibili(
    Dio client,
    LiveAccountSession session,
  ) async {
    final body = await _get(
      client,
      session,
      Uri.parse('https://api.bilibili.com/x/member/web/account'),
      'https://www.bilibili.com/',
    );
    if (_code(body['code']) == -101) return _expired('哔哩哔哩');
    final data = body['data'];
    if (_code(body['code']) != 0 || data is! Map) return _unavailable;
    final userId = _userId(data['mid']);
    if (userId == null) return _unavailable;
    return LiveAccountValidation(
      status: LiveAccountStatus.verified,
      message: '账号身份已验证',
      userId: userId,
      displayName: _text(data['uname']),
      avatarUrl: _text(data['face']),
    );
  }

  static Future<LiveAccountValidation> _douyu(
    Dio client,
    LiveAccountSession session,
  ) async {
    // Use the official site's current-user header endpoint. Passport safeAuth
    // can reject a valid website session that getH5Play accepts for original
    // quality, so its response cannot establish website login or expiry.
    final body = await _get(
      client,
      session,
      Uri.https('www.douyu.com', '/lapi/member/api/getInfo', {
        'client_type': '0',
        'd': DateTime.now().millisecondsSinceEpoch.toString(),
      }),
      'https://www.douyu.com/',
    );
    final data = body['msg'];
    if (data is! Map) return _unavailable;
    // Anonymous, UID-only and invalid-session controls all return this
    // explicit signed-out shape. Other errors remain retryable.
    if (_code(body['error']) == 1 && _code(data['uid']) == 0) {
      return _expired('斗鱼');
    }
    final userId = _userId(data['uid']);
    if (_code(body['error']) != 0 || userId == null) return _unavailable;
    final info = data['info'];
    return LiveAccountValidation(
      status: LiveAccountStatus.verified,
      message: '斗鱼已确认登录；进入直播间可查看实际返回的画质',
      userId: userId,
      displayName: info is Map ? _text(info['nn']) : null,
      avatarUrl: info is Map ? _text(info['icon']) : null,
    );
  }

  static Future<LiveAccountValidation> _huya(
    Dio client,
    LiveAccountSession session,
  ) async {
    final body = await _get(
      client,
      session,
      Uri.https('l.huya.com', '/udb_web/udbport2.php', {
        'm': 'HuyaLogin',
        'do': 'checkLogin',
      }),
      'https://www.huya.com/',
    );
    if (body['isLogined'] == false) return _expired('虎牙');
    final userId = _userId(body['uid']);
    if (body['isLogined'] != true || userId == null) return _unavailable;
    return LiveAccountValidation(
      status: LiveAccountStatus.verified,
      message: '虎牙已确认登录',
      userId: userId,
      displayName: _text(body['userNick']) ?? _text(body['userName']),
      avatarUrl: _text(body['userLogo']),
    );
  }

  static Future<LiveAccountValidation> _douyin(
    Dio client,
    LiveAccountSession session,
  ) async {
    final body = await _get(
      client,
      session,
      Uri.https('live.douyin.com', '/webcast/user/me/', {
        'aid': '6383',
        'device_platform': 'web',
      }),
      'https://live.douyin.com/',
    );
    if (_code(body['status_code']) == 20003) return _expired('抖音');
    final data = body['data'];
    if (_code(body['status_code']) != 0 || data is! Map) return _unavailable;
    final userId = _userId(data['id_str']) ?? _userId(data['id']);
    if (userId == null) return _unavailable;
    final avatar = data['avatar_thumb'];
    final urls = avatar is Map ? avatar['url_list'] : null;
    return LiveAccountValidation(
      status: LiveAccountStatus.verified,
      message: '抖音已确认登录',
      userId: userId,
      displayName: _text(data['nickname']),
      avatarUrl: urls is List && urls.isNotEmpty ? _text(urls.first) : null,
    );
  }
}

/// Per-request metadata wrapper; only the map entries become HTTP headers.
class AccountRequestHeaders extends MapBase<String, String> {
  final Map<String, String> _headers;
  final void Function(Uri, Iterable<String>) acceptResponseCookies;
  AccountRequestHeaders(Map<String, String> headers, this.acceptResponseCookies)
    : _headers = Map.of(headers);
  @override
  String? operator [](Object? key) => _headers[key];
  @override
  void operator []=(String key, String value) {
    _headers[key] = value;
  }

  @override
  void clear() => _headers.clear();
  @override
  Iterable<String> get keys => _headers.keys;
  @override
  String? remove(Object? key) => _headers.remove(key);
  @override
  String toString() => 'AccountRequestHeaders([redacted])';
}
