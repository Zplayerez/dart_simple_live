import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:simple_live_account/simple_live_account.dart';
import 'package:simple_live_account/widgets/account_labels.dart';
import 'package:simple_live_app/modules/mine/account/platform_web_cookie_cleanup.dart';
import 'package:simple_live_app/modules/mine/account/platform_web_login_environment.dart';
import 'package:simple_live_app/modules/mine/account/platform_web_login_policy.dart';

enum _LoginPhase { preparing, creating, loading, ready, failed }

/// Login is completed by the user on the official site. No password entry,
/// captcha solving or Cookie JavaScript is implemented by this application.
class PlatformWebLoginPage extends StatefulWidget {
  final String siteId;

  /// Allows widget tests to exercise native lifecycle failures without a runtime.
  @visibleForTesting
  final Future<WebViewEnvironment?> Function()? prepareEnvironment;

  const PlatformWebLoginPage({
    required this.siteId,
    this.prepareEnvironment,
    super.key,
  });

  @override
  State<PlatformWebLoginPage> createState() => _PlatformWebLoginPageState();
}

class _PlatformWebLoginPageState extends State<PlatformWebLoginPage> {
  WebViewEnvironment? _environment;
  Widget? _view;
  Uri? _currentUri;
  bool _busy = false;
  _LoginPhase _phase = _LoginPhase.preparing;
  String? _error;
  Timer? _deadline;
  int _generation = 0;

  bool get _loading =>
      _phase == _LoginPhase.preparing ||
      _phase == _LoginPhase.creating ||
      _phase == _LoginPhase.loading;

  bool _active(int generation) =>
      mounted && generation == _generation && _phase != _LoginPhase.failed;

  @override
  void initState() {
    super.initState();
    // WebView event diagnostics can contain callback URLs and authorization data.
    PlatformInAppWebViewController.debugLoggingSettings.enabled = false;
    PlatformWebViewEnvironment.debugLoggingSettings.enabled = false;
    _prepare();
  }

  @override
  void dispose() {
    _deadline?.cancel();
    super.dispose();
  }

  void _fail(int generation, String message) {
    if (!_active(generation)) return;
    _deadline?.cancel();
    setState(() {
      _phase = _LoginPhase.failed;
      _error = message;
    });
  }

  void _startDeadline(int generation, String message) {
    _deadline?.cancel();
    _deadline =
        Timer(const Duration(seconds: 30), () => _fail(generation, message));
  }

  Future<void> _prepare() async {
    final generation = ++_generation;
    _deadline?.cancel();
    setState(() {
      _phase = _LoginPhase.preparing;
      _environment = null;
      _view = null;
      _currentUri = null;
      _error = null;
    });
    try {
      if (widget.prepareEnvironment == null && !platformWebLoginSupported) {
        _fail(generation, '当前系统暂不支持应用内网页登录，请使用 Cookie 导入。');
        return;
      }
      final environment = await (widget.prepareEnvironment ??
          preparePlatformWebLoginEnvironment)();
      if (!_active(generation)) return;
      setState(() {
        _environment = environment;
        _view = _buildWebView(generation);
        _phase = _LoginPhase.creating;
      });
      // Native view creation errors do not reach onReceivedError on Windows.
      _startDeadline(generation, '网页登录组件启动超时，请重试；若仍无法打开，请使用 Cookie 导入。');
    } on PlatformWebLoginEnvironmentException catch (error) {
      _fail(generation, error.message);
    } catch (_) {
      _fail(generation, '无法启动网页登录组件，请重试或使用 Cookie 导入。');
    }
  }

  Future<void> _created(
      int generation, InAppWebViewController controller) async {
    if (!_active(generation)) return;
    setState(() => _phase = _LoginPhase.loading);
    _startDeadline(generation, '官方页面加载超时，请检查网络后重试，或使用 Cookie 导入。');
    try {
      // Wait for the native controller and event channel before navigating.
      await controller.loadUrl(
          urlRequest: URLRequest(
        url: WebUri(officialLoginUrls[widget.siteId]!),
      ));
    } catch (_) {
      _fail(generation, '无法打开平台官方网站，请重试或使用 Cookie 导入。');
    }
  }

  bool _recordLocation(int generation, Uri? uri) {
    if (!_active(generation)) return false;
    // A newly created Windows view may report its initial blank document.
    if (uri == null || uri.toString() == 'about:blank') return false;
    if (!isOfficialAccountPage(widget.siteId, uri)) {
      _fail(generation, '已阻止离开平台官方网站，请重试或使用 Cookie 导入。');
      return false;
    }
    setState(() => _currentUri = uri);
    recordPlatformWebCookieScope(widget.siteId, uri);
    return true;
  }

  Future<void> _complete() async {
    if (_busy || _phase != _LoginPhase.ready) return;
    if (!isOfficialAccountPage(widget.siteId, _currentUri)) return;
    setState(() => _busy = true);
    try {
      final cookieManager =
          CookieManager.instance(webViewEnvironment: _environment);
      final header = await collectOfficialAccountCookieHeader(
        widget.siteId,
        readCookies: (uri) async {
          final values = await cookieManager.getCookies(url: WebUri.uri(uri));
          return values
              .map((cookie) => OfficialWebCookie(
                    name: cookie.name,
                    value: cookie.value,
                    domain: cookie.domain,
                  ))
              .toList();
        },
      );
      if (!mounted) return;
      if (header == null) {
        SmartDialog.showToast('尚未读取到可导入的账号凭据。若官网已登录，请返回平台首页后重试，或使用 Cookie 导入。');
        return;
      }
      final state = await PlatformAccountManager.instance
          .importCookie(widget.siteId, header);
      if (!mounted) return;
      SmartDialog.showToast(accountResultMessage(state));
      Get.back();
    } catch (_) {
      if (mounted) {
        setState(() => _error = '无法读取或验证网页登录凭据，请重试或使用 Cookie 导入。');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _buildWebView(int generation) => InAppWebView(
        key: ValueKey(generation),
        webViewEnvironment: _environment,
        initialSettings: InAppWebViewSettings(
          useShouldOverrideUrlLoading: true,
          userAgent: widget.siteId == 'bilibili' &&
                  (Platform.isAndroid || Platform.isIOS)
              ? 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1'
              : null,
        ),
        onWebViewCreated: (controller) => _created(generation, controller),
        onLoadStart: (_, uri) {
          if (!_recordLocation(generation, uri)) return;
          // A redirect must not repeatedly extend the loading deadline.
          if (_phase == _LoginPhase.ready) {
            _startDeadline(generation, '官方页面加载超时，请检查网络后重试。');
          }
          setState(() => _phase = _LoginPhase.loading);
        },
        onUpdateVisitedHistory: (_, uri, __) =>
            _recordLocation(generation, uri),
        onLoadStop: (_, uri) {
          if (!_recordLocation(generation, uri)) return;
          _deadline?.cancel();
          setState(() {
            _phase = _LoginPhase.ready;
            _error = null;
          });
        },
        onReceivedError: (_, request, error) {
          // WebView2 reports our rejected offsite navigations as CANCELLED.
          // These must not tear down an already loaded official page.
          if (request.isForMainFrame == false ||
              error.type == WebResourceErrorType.CANCELLED) {
            return;
          }
          _fail(generation, '官方页面加载失败，请检查网络后重试，或使用 Cookie 导入。');
        },
        onReceivedHttpError: (_, request, response) {
          if (request.isForMainFrame == false ||
              (response.statusCode ?? 0) < 400) {
            return;
          }
          _fail(generation, '官方网站暂时无法打开，请稍后重试，或使用 Cookie 导入。');
        },
        shouldOverrideUrlLoading: (_, navigation) async {
          if (!_active(generation)) return NavigationActionPolicy.CANCEL;
          final allowed = isAllowedAccountNavigation(
              widget.siteId, navigation.request.url,
              isMainFrame: navigation.isForMainFrame);
          if (!allowed && navigation.isForMainFrame) {
            // Keep the existing official page usable when an external link is blocked.
            setState(() => _error = '已阻止离开平台官方网站；第三方登录请使用 Cookie 导入。');
          }
          return allowed
              ? NavigationActionPolicy.ALLOW
              : NavigationActionPolicy.CANCEL;
        },
      );

  @override
  Widget build(BuildContext context) {
    final status = switch (_phase) {
      _LoginPhase.preparing => '正在准备网页登录组件',
      _LoginPhase.creating => '正在启动网页登录组件',
      _LoginPhase.loading => '正在加载平台官方网站',
      _LoginPhase.ready => '在官网完成登录及验证码，再点击“完成登录”。账号状态将单独验证。',
      _LoginPhase.failed => '网页登录未能打开',
    };
    return Scaffold(
      appBar: AppBar(
        title: Text('${accountPlatformName(widget.siteId)}网页登录'),
        actions: [
          TextButton(
            onPressed: _busy || _phase != _LoginPhase.ready ? null : _complete,
            child: const Text('完成登录'),
          )
        ],
      ),
      body: Column(children: [
        if (_currentUri != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: Text('当前网站：${_currentUri!.host}'),
          ),
        Padding(
            padding: const EdgeInsets.all(12), child: Text(_error ?? status)),
        if (_busy || _loading) const LinearProgressIndicator(),
        if (_phase == _LoginPhase.creating ||
            _phase == _LoginPhase.loading ||
            _phase == _LoginPhase.ready)
          Expanded(child: _view!),
        if (_error != null)
          TextButton(
            onPressed: _busy ? null : _prepare,
            child: const Text('重试打开官网'),
          ),
      ]),
    );
  }
}
