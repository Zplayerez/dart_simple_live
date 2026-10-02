import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:simple_live_account/simple_live_account.dart';
import 'package:simple_live_account/widgets/account_labels.dart';
import 'package:simple_live_app/modules/mine/account/platform_web_login_policy.dart';
import 'package:simple_live_app/modules/mine/account/platform_web_cookie_cleanup.dart';

/// Login is completed by the user on the official site. No password entry,
/// captcha solving or Cookie JavaScript is implemented by this application.
class PlatformWebLoginPage extends StatefulWidget {
  final String siteId;

  const PlatformWebLoginPage({required this.siteId, super.key});

  @override
  State<PlatformWebLoginPage> createState() => _PlatformWebLoginPageState();
}

class _PlatformWebLoginPageState extends State<PlatformWebLoginPage> {
  InAppWebViewController? _webView;
  Uri? _currentUri;
  bool _busy = false;
  bool _blockedNavigation = false;
  bool _ready = false;
  bool _initializing = true;

  @override
  void initState() {
    super.initState();
    // WebView event diagnostics can contain callback URLs and authorization data.
    PlatformInAppWebViewController.debugLoggingSettings.enabled = false;
    PlatformWebViewEnvironment.debugLoggingSettings.enabled = false;
    _prepare();
  }

  Future<void> _prepare() async {
    var ready = platformWebLoginSupported;
    String? error;
    if (!ready) {
      error = '当前系统暂不支持应用内网页登录，请使用 Cookie 导入。';
    } else if (Platform.isWindows) {
      try {
        final version = await WebViewEnvironment.getAvailableVersion();
        ready = version != null && version.isNotEmpty;
      } catch (_) {
        ready = false;
      }
      if (!ready) {
        error = '网页登录组件不可用，请安装 Microsoft Edge WebView2 Runtime，或使用 Cookie 导入。';
      }
    }
    if (!mounted) return;
    setState(() {
      _ready = ready;
      _initializing = false;
      _error = error;
    });
  }

  String? _error;

  Future<void> _recordLocation(
      InAppWebViewController controller, Uri? uri) async {
    if (!mounted) return;
    final official = isOfficialAccountPage(widget.siteId, uri);
    setState(() {
      _currentUri = uri;
      _blockedNavigation = uri != null && !official;
      if (_blockedNavigation) _error = '已阻止离开平台官方网站，请返回官网或使用 Cookie 导入。';
    });
    recordPlatformWebCookieScope(widget.siteId, uri);
    if (_blockedNavigation) await controller.stopLoading();
  }

  Future<void> _complete() async {
    if (_busy || !_ready) return;
    if (!isOfficialAccountPage(widget.siteId, _currentUri)) {
      SmartDialog.showToast('请在平台官方页面完成登录后再点击完成登录');
      return;
    }
    setState(() => _busy = true);
    try {
      final root = officialCookieRoots[widget.siteId]!;
      final cookieManager = CookieManager.instance();
      final cookies = <OfficialWebCookie>[];
      // Never collect another platform's jar or enumerate all browser cookies.
      for (final host in [root, 'www.$root']) {
        final values =
            await cookieManager.getCookies(url: WebUri('https://$host/'));
        if (!mounted) return;
        cookies.addAll(values.map((cookie) => OfficialWebCookie(
              name: cookie.name,
              value: cookie.value,
              domain: cookie.domain,
            )));
      }
      final header = officialAccountCookieHeader(widget.siteId, cookies);
      if (header == null) {
        SmartDialog.showToast('尚未获取到账号会话，请先在官网点击登录并完成验证');
        return;
      }
      final state = await PlatformAccountManager.instance
          .importCookie(widget.siteId, header);
      if (!mounted) return;
      SmartDialog.showToast(accountResultMessage(state));
      // The account page shows configured/unavailable separately from verified.
      Get.back();
    } catch (_) {
      if (mounted) {
        setState(() => _error = '无法读取或验证网页登录凭据，请重试或使用 Cookie 导入。');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('${accountPlatformName(widget.siteId)}网页登录'),
        actions: [
          TextButton(
            onPressed: _busy || !_ready ? null : _complete,
            child: const Text('完成登录'),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: Text(_currentUri?.host.isNotEmpty == true
                ? '当前网站：${_currentUri!.host}'
                : '正在打开平台官方网站'),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(_error ?? '在官网完成登录及验证码，再点击“完成登录”。账号状态将单独验证。'),
          ),
          if (_busy) const LinearProgressIndicator(),
          if (_initializing) const LinearProgressIndicator(),
          if (_ready)
            Expanded(
              child: Stack(children: [
                InAppWebView(
                  initialUrlRequest: URLRequest(
                      url: WebUri(officialLoginUrls[widget.siteId]!)),
                  initialSettings: InAppWebViewSettings(
                    useShouldOverrideUrlLoading: true,
                    // Desktop official pages keep their native login layout.
                    userAgent: widget.siteId == 'bilibili' &&
                            (Platform.isAndroid || Platform.isIOS)
                        ? 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1'
                        : null,
                  ),
                  onWebViewCreated: (controller) {
                    if (mounted) _webView = controller;
                  },
                  onLoadStart: _recordLocation,
                  onUpdateVisitedHistory: (controller, uri, _) =>
                      _recordLocation(controller, uri),
                  onLoadStop: _recordLocation,
                  onReceivedError: (_, request, error) {
                    if (!mounted || request.isForMainFrame == false) return;
                    setState(() => _error = '官方页面加载失败，请检查网络后重试，或使用 Cookie 导入。');
                  },
                  shouldOverrideUrlLoading: (_, navigation) async {
                    final allowed = isAllowedAccountNavigation(
                        widget.siteId, navigation.request.url,
                        isMainFrame: navigation.isForMainFrame);
                    if (!allowed && navigation.isForMainFrame && mounted) {
                      setState(
                          () => _error = '已阻止离开平台官方网站；第三方登录请使用 Cookie 导入。');
                    }
                    return allowed
                        ? NavigationActionPolicy.ALLOW
                        : NavigationActionPolicy.CANCEL;
                  },
                ),
                if (_blockedNavigation)
                  Positioned.fill(
                      child: ColoredBox(
                    color: Theme.of(context).scaffoldBackgroundColor,
                    child: const Center(child: Text('已阻止显示非官方网站')),
                  )),
              ]),
            ),
          if (_error != null && _ready)
            TextButton(
              onPressed: () {
                setState(() {
                  _error = null;
                  _blockedNavigation = false;
                  _currentUri = null;
                });
                _webView?.loadUrl(
                    urlRequest: URLRequest(
                        url: WebUri(officialLoginUrls[widget.siteId]!)));
              },
              child: const Text('重试打开官网'),
            ),
        ],
      ),
    );
  }
}
