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

  bool permits(Uri uri) =>
      uri.scheme == 'https' &&
      uri.port == 443 &&
      uri.userInfo.isEmpty &&
      _hosts[platform]!.contains(uri.host.toLowerCase());

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
    if (session.platform != LiveAccountPlatform.bilibili) {
      final message = switch (session.platform) {
        LiveAccountPlatform.douyu => '登录信息已保存并用于获取播放地址；身份与可用画质尚未确认',
        LiveAccountPlatform.huya => '登录信息已保存；当前播放线路尚未验证账号画质权限',
        LiveAccountPlatform.douyin =>
          session.cookie.hasAccountSessionFor(LiveAccountPlatform.douyin)
              ? '登录信息已保存；账号身份与可用画质尚未确认'
              : '仅保存了游客设备信息，请通过网页登录获取账号权限',
        _ => '',
      };
      return LiveAccountValidation(
        status: LiveAccountStatus.configured,
        message: message,
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
    final uri = Uri.parse('https://api.bilibili.com/x/member/web/account');
    try {
      final response = await client.getUri(
        uri,
        options: Options(
          headers: session.headersFor(uri),
          followRedirects: false,
          validateStatus: (status) => status != null && status < 500,
        ),
      );
      dynamic body = response.data;
      if (body is String) body = jsonDecode(body);
      if (body is Map && body['code'] == -101) {
        return const LiveAccountValidation(
          status: LiveAccountStatus.expired,
          message: '平台已明确返回未登录，请更新 Cookie',
        );
      }
      if (body is Map &&
          body['code'] == 0 &&
          body['data'] is Map &&
          body['data']['mid'] != null) {
        final data = body['data'] as Map;
        return LiveAccountValidation(
          status: LiveAccountStatus.verified,
          message: '账号身份已验证',
          userId: data['mid'].toString(),
          displayName: data['uname']?.toString(),
          avatarUrl: data['face']?.toString(),
        );
      }
      return const LiveAccountValidation(
        status: LiveAccountStatus.unavailable,
        message: '平台暂未提供可确认的身份结果，已保留 Cookie',
      );
    } catch (_) {
      return const LiveAccountValidation(
        status: LiveAccountStatus.unavailable,
        message: '暂时无法验证账号，请稍后重试；已保留 Cookie',
      );
    } finally {
      if (dio == null) client.close();
    }
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
