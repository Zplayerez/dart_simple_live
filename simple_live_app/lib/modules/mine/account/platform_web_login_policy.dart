import 'dart:io';

import 'package:simple_live_core/simple_live_core.dart';

const officialLoginUrls = {
  'bilibili': 'https://passport.bilibili.com/login',
  'douyu': 'https://www.douyu.com/',
  'huya': 'https://www.huya.com/',
  'douyin': 'https://www.douyin.com/',
};

const officialCookieRoots = {
  'bilibili': 'bilibili.com',
  'douyu': 'douyu.com',
  'huya': 'huya.com',
  'douyin': 'douyin.com',
};

bool get platformWebLoginSupported =>
    Platform.isAndroid ||
    Platform.isIOS ||
    Platform.isWindows ||
    Platform.isMacOS;

bool isOfficialAccountHost(String siteId, String host) {
  final root = officialCookieRoots[siteId];
  if (root == null) return false;
  final normalized = host.toLowerCase().replaceFirst(RegExp(r'^\.'), '');
  return normalized == root || normalized.endsWith('.$root');
}

bool isOfficialAccountPage(String siteId, Uri? uri) =>
    uri != null &&
    uri.scheme == 'https' &&
    isOfficialAccountHost(siteId, uri.host);

/// Keep top-level login pages on the selected platform. Official pages may
/// embed HTTPS captcha/identity resources, but external SSO navigation is not
/// enabled until that provider's complete flow has been verified.
bool isAllowedAccountNavigation(String siteId, Uri? uri,
    {required bool isMainFrame}) {
  if (isMainFrame) return isOfficialAccountPage(siteId, uri);
  return uri != null &&
      (uri.scheme == 'https' || uri.toString() == 'about:blank');
}

/// Metadata returned by the native Cookie manager, never by page JavaScript.
class OfficialWebCookie {
  const OfficialWebCookie(
      {required this.name, required this.value, this.domain});
  final String name;
  final String value;
  final String? domain;
}

enum PlatformWebCookieCollectionFailure { read, format }

class PlatformWebCookieCollectionException implements Exception {
  final PlatformWebCookieCollectionFailure failure;

  const PlatformWebCookieCollectionException(this.failure);

  String get message => switch (failure) {
        PlatformWebCookieCollectionFailure.read => '无法读取浏览器登录凭据，请点击“完成登录”重试。',
        PlatformWebCookieCollectionFailure.format =>
          '浏览器登录凭据格式无法识别，请重试或使用 Cookie 导入。',
      };

  @override
  String toString() => message;
}

/// Read only the existing platform root/www scopes. In particular, credentials
/// from a visited account subdomain are not widened into a shared Cookie header.
Future<String?> collectOfficialAccountCookieHeader(
  String siteId, {
  required Future<List<OfficialWebCookie>> Function(Uri uri) readCookies,
}) async {
  final root = officialCookieRoots[siteId];
  if (root == null) {
    throw const PlatformWebCookieCollectionException(
        PlatformWebCookieCollectionFailure.format);
  }
  final cookies = <OfficialWebCookie>[];
  try {
    for (final host in [root, 'www.$root']) {
      cookies.addAll(
          await readCookies(Uri(scheme: 'https', host: host, path: '/')));
    }
  } catch (_) {
    throw const PlatformWebCookieCollectionException(
        PlatformWebCookieCollectionFailure.read);
  }
  try {
    return officialAccountCookieHeader(siteId, cookies);
  } on FormatException {
    throw const PlatformWebCookieCollectionException(
        PlatformWebCookieCollectionFailure.format);
  }
}

/// Called only for CookieManager results read from this platform's HTTPS origin.
/// A missing native domain is allowed because Android's Cookie API omits it.
String? officialAccountCookieHeader(
    String siteId, Iterable<OfficialWebCookie> cookies) {
  final values = <String, String>{};
  for (final cookie in cookies) {
    if (cookie.domain != null &&
        cookie.domain!.isNotEmpty &&
        !isOfficialAccountHost(siteId, cookie.domain!)) {
      continue;
    }
    // A browser can store nameless/non-token auxiliary cookies. Skip each one
    // instead of letting it poison an otherwise valid account session header.
    if (!PlatformCookie.isValidName(cookie.name) ||
        cookie.value.contains(';') ||
        RegExp(r'[\x00-\x1f\x7f]').hasMatch('${cookie.name}${cookie.value}')) {
      continue;
    }
    values[cookie.name] = cookie.value;
  }
  final parsed = PlatformCookie.parse(
    values.entries.map((entry) => '${entry.key}=${entry.value}').join('; '),
  );
  final platform =
      LiveAccountPlatform.values.firstWhere((value) => value.name == siteId);
  if (!parsed.hasAccountSessionFor(platform)) return null;
  return parsed.header;
}
