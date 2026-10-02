import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:simple_live_app/modules/mine/account/platform_web_login_policy.dart';

const _officialHosts = {
  'bilibili': [
    'bilibili.com',
    'www.bilibili.com',
    'm.bilibili.com',
    'passport.bilibili.com',
    'api.bilibili.com',
    'live.bilibili.com'
  ],
  'douyu': ['douyu.com', 'www.douyu.com', 'passport.douyu.com', 'm.douyu.com'],
  'huya': ['huya.com', 'www.huya.com', 'lgn.huya.com', 'm.huya.com'],
  'douyin': ['douyin.com', 'www.douyin.com', 'live.douyin.com'],
};
final _observedScopes = <String, Set<Uri>>{};

/// Android exposes cookies for a URL but omits domain/path metadata. Remember
/// official paths visited by our login view so their scoped cookies can be
/// removed too; never retain callback query strings or fragments.
void recordPlatformWebCookieScope(String siteId, Uri? uri) {
  if (!isOfficialAccountPage(siteId, uri)) return;
  final scopes = _observedScopes.putIfAbsent(siteId, () => <Uri>{});
  for (final path in _pathScopes(uri!.path)) {
    scopes.add(Uri(scheme: 'https', host: uri.host, path: path));
  }
}

Set<String> _pathScopes(String path) {
  final paths = <String>{'/'};
  var prefix = '';
  for (final segment in path.split('/').where((value) => value.isNotEmpty)) {
    prefix += '/$segment';
    paths.add(prefix);
    paths.add('$prefix/');
  }
  return paths;
}

/// Testable policy shared by native enumeration adapters. Enumeration may
/// include other platforms, but only the chosen platform is ever modified.
Future<void> clearEnumeratedPlatformWebCookies(
  String siteId, {
  required Future<List<Cookie>> Function() readCookies,
  required Future<bool> Function(Cookie cookie) deleteCookie,
}) async {
  bool selected(Cookie cookie) =>
      cookie.domain != null && isOfficialAccountHost(siteId, cookie.domain!);
  final cookies = await readCookies();
  for (final cookie in cookies.where(selected)) {
    if (!await deleteCookie(cookie)) {
      throw StateError('未能清除平台网页登录凭据');
    }
  }
  if ((await readCookies()).any(selected)) {
    throw StateError('平台网页登录凭据仍存在，请重试退出');
  }
}

Future<void> clearNativePlatformWebCookies(String siteId) async {
  if (!platformWebLoginSupported) return;
  if (!officialCookieRoots.containsKey(siteId)) {
    throw ArgumentError('Unsupported account platform');
  }
  PlatformInAppWebViewController.debugLoggingSettings.enabled = false;
  PlatformWebViewEnvironment.debugLoggingSettings.enabled = false;
  if (Platform.isWindows) {
    await _clearWindowsCookies(siteId);
    return;
  }
  final manager = CookieManager.instance();
  if (Platform.isIOS || Platform.isMacOS) {
    await clearEnumeratedPlatformWebCookies(
      siteId,
      readCookies: () => manager.getAllCookies(),
      deleteCookie: (cookie) => manager.deleteCookie(
        url: WebUri.uri(Uri(
            scheme: 'https',
            host: cookie.domain!.replaceFirst(RegExp(r'^\.'), ''),
            path: cookie.path ?? '/')),
        name: cookie.name,
        domain: cookie.domain,
        path: cookie.path ?? '/',
      ),
    );
  } else if (Platform.isAndroid) {
    await _clearAndroidCookies(siteId, manager);
  }
  _observedScopes.remove(siteId);
}

Future<void> _clearWindowsCookies(String siteId) async {
  final created = Completer<InAppWebViewController>();
  final view = HeadlessInAppWebView(
    initialUrlRequest: URLRequest(url: WebUri('about:blank')),
    initialSettings: InAppWebViewSettings(javaScriptEnabled: false),
    onWebViewCreated: (controller) {
      if (!created.isCompleted) created.complete(controller);
    },
  );
  try {
    await view.run().timeout(const Duration(seconds: 10));
    final controller =
        await created.future.timeout(const Duration(seconds: 10));
    await clearEnumeratedPlatformWebCookies(
      siteId,
      readCookies: () async {
        final result = await controller
            .callDevToolsProtocolMethod(
              methodName: 'Storage.getCookies',
            )
            .timeout(const Duration(seconds: 10));
        if (result is! Map || result['cookies'] is! List) {
          throw StateError('无法检查平台网页登录凭据');
        }
        // Cookie values are not needed for logout and never leave this adapter.
        return (result['cookies'] as List)
            .map((item) => Cookie(
                  name: item['name'] as String,
                  value: '',
                  domain: item['domain'] as String,
                  path: item['path'] as String,
                ))
            .toList();
      },
      deleteCookie: (cookie) async {
        final result = await controller.callDevToolsProtocolMethod(
          methodName: 'Network.deleteCookies',
          parameters: {
            'name': cookie.name,
            'domain': cookie.domain,
            'path': cookie.path
          },
        ).timeout(const Duration(seconds: 10));
        return result is Map && !result.containsKey('error');
      },
    );
    _observedScopes.remove(siteId);
  } finally {
    await view.dispose().timeout(const Duration(seconds: 5));
  }
}

Future<void> _clearAndroidCookies(String siteId, CookieManager manager) async {
  final root = officialCookieRoots[siteId]!;
  final scopes = <Uri>{
    for (final host in _officialHosts[siteId]!)
      Uri(scheme: 'https', host: host, path: '/'),
    ...?_observedScopes[siteId],
  };
  // Include known login routes even after a restart. Android's native Cookie
  // API cannot enumerate arbitrary paths that were never visited by this app.
  final loginUri = Uri.parse(officialLoginUrls[siteId]!);
  for (final path in _pathScopes(loginUri.path)) {
    scopes.add(Uri(scheme: 'https', host: loginUri.host, path: path));
  }
  final removals = <(String, String, String, String)>{};
  for (final scope in scopes) {
    final cookies = await manager.getCookies(url: WebUri.uri(scope));
    final domains = <String>{};
    var domain = scope.host;
    while (isOfficialAccountHost(siteId, domain)) {
      domains.addAll({domain, '.$domain'});
      if (domain == root) break;
      domain = domain.substring(domain.indexOf('.') + 1);
    }
    for (final cookie in cookies) {
      for (final domain in domains) {
        for (final path in _pathScopes(scope.path)) {
          removals.add((scope.host, cookie.name, domain, path));
        }
      }
    }
  }
  for (final (host, name, domain, path) in removals) {
    final deleted = await manager.deleteCookie(
      url: WebUri.uri(Uri(scheme: 'https', host: host, path: path)),
      name: name,
      domain: domain,
      path: path,
    );
    if (!deleted) throw StateError('未能清除平台网页登录凭据');
  }
  for (final scope in scopes) {
    if ((await manager.getCookies(url: WebUri.uri(scope))).isNotEmpty) {
      throw StateError('平台网页登录凭据仍存在，请重试退出');
    }
  }
}
