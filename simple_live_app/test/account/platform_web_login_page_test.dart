import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:simple_live_account/simple_live_account.dart';
import 'package:simple_live_app/modules/mine/account/platform_web_login_environment.dart';
import 'package:simple_live_app/modules/mine/account/platform_web_login_page.dart';

class _Controller extends PlatformInAppWebViewController {
  _Controller()
      : super.implementation(
            const PlatformInAppWebViewControllerCreationParams(id: 'test'));
  final urls = <WebUri?>[];
  bool failLoad = false;

  @override
  Future<void> loadUrl(
      {required URLRequest urlRequest,
      Uri? iosAllowingReadAccessTo,
      WebUri? allowingReadAccessTo}) async {
    if (failLoad) throw StateError('synthetic private native error');
    urls.add(urlRequest.url);
  }
}

class _View extends PlatformInAppWebViewWidget {
  _View(super.params) : super.implementation();
  @override
  Widget build(BuildContext context) => const SizedBox.expand();
  @override
  T controllerFromPlatform<T>(PlatformInAppWebViewController controller) =>
      InAppWebViewController.fromPlatform(platform: controller) as T;
  @override
  void dispose() {}
}

class _WebPlatform extends InAppWebViewPlatform {
  final views = <_View>[];
  Future<List<Cookie>> Function(WebUri) readCookies = (_) async => [];
  @override
  PlatformCookieManager createPlatformCookieManager(
          PlatformCookieManagerCreationParams params) =>
      _Cookies(params, (url) => readCookies(url));
  @override
  PlatformInAppWebViewWidget createPlatformInAppWebViewWidget(
      PlatformInAppWebViewWidgetCreationParams params) {
    final view = _View(params);
    views.add(view);
    return view;
  }
}

class _Cookies extends PlatformCookieManager {
  _Cookies(super.params, this.read) : super.implementation();
  final Future<List<Cookie>> Function(WebUri) read;
  @override
  Future<List<Cookie>> getCookies({
    required WebUri url,
    PlatformInAppWebViewController? iosBelow11WebViewController,
    PlatformInAppWebViewController? webViewController,
  }) =>
      read(url);
}

class _Environment extends PlatformWebViewEnvironment {
  _Environment()
      : super.implementation(const PlatformWebViewEnvironmentCreationParams());
  @override
  String get id => 'synthetic-cookie-environment';
}

class _CountingAccountManager extends PlatformAccountManager {
  _CountingAccountManager() : super(sites: {});

  int importCalls = 0;

  @override
  Future<PlatformAccountState> importCookie(String siteId, String raw,
      {bool verify = true}) async {
    importCalls++;
    return PlatformAccountState(
        siteId: siteId, status: LiveAccountStatus.configured);
  }
}

void main() {
  late _WebPlatform platform;
  late _Controller nativeController;
  late InAppWebViewController controller;
  final official = WebUri('https://www.douyu.com/');

  setUp(() {
    Get.testMode = true;
    platform = _WebPlatform();
    InAppWebViewPlatform.instance = platform;
    nativeController = _Controller();
    controller =
        InAppWebViewController.fromPlatform(platform: nativeController);
  });
  tearDown(() => Get.reset());

  Future<void> mount(WidgetTester tester,
      {Future<WebViewEnvironment?> Function()? prepare}) async {
    await tester.pumpWidget(MaterialApp(
        home: PlatformWebLoginPage(
      siteId: 'douyu',
      prepareEnvironment: prepare ?? () async => null,
    )));
    await tester.pump();
  }

  bool canComplete(WidgetTester tester) =>
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, '完成登录'))
          .onPressed !=
      null;

  Future<void> readyForCollection(WidgetTester tester) async {
    await mount(tester,
        prepare: () async =>
            WebViewEnvironment.fromPlatform(platform: _Environment()));
    final callbacks = platform.views.single.params;
    callbacks.onWebViewCreated!(controller);
    callbacks.onLoadStop!(controller, official);
    await tester.pump();
  }

  testWidgets(
      'read failure clears busy and retry replaces stale error with progress',
      (tester) async {
    final accounts = _CountingAccountManager();
    Get.put<PlatformAccountManager>(accounts);
    platform.readCookies = (_) async => throw StateError('synthetic-private');
    await readyForCollection(tester);
    await tester.tap(find.text('完成登录'));
    await tester.pump();
    expect(find.textContaining('无法读取浏览器登录凭据'), findsOneWidget);
    expect(find.textContaining('synthetic-private'), findsNothing);
    expect(canComplete(tester), isTrue);
    expect(find.byType(LinearProgressIndicator), findsNothing);

    final pending = Completer<List<Cookie>>();
    platform.readCookies = (_) => pending.future;
    await tester.tap(find.text('完成登录'));
    await tester.pump();
    expect(find.textContaining('无法读取浏览器登录凭据'), findsNothing);
    expect(find.text('正在读取浏览器登录凭据'), findsOneWidget);
    expect(canComplete(tester), isFalse);
    await tester.pump(const Duration(seconds: 16));
    expect(find.textContaining('读取浏览器登录凭据超时'), findsOneWidget);
    expect(canComplete(tester), isTrue);
    expect(accounts.importCalls, 0);
    pending.complete([
      Cookie(name: 'acf_auth', value: 'synthetic-late', domain: '.douyu.com'),
    ]);
    await tester.pump();
    expect(find.textContaining('读取浏览器登录凭据超时'), findsOneWidget);
    expect(find.textContaining('未能导入'), findsNothing);
    expect(accounts.importCalls, 0);
  });

  testWidgets(
      'unsupported auxiliary cookies do not turn an import error into a read error',
      (tester) async {
    platform.readCookies = (_) async => [
          Cookie(name: '', value: 'synthetic-nameless', domain: '.douyu.com'),
          Cookie(name: 'auxiliary', value: 42, domain: '.douyu.com'),
          Cookie(name: 'emptyAuxiliary', value: null, domain: '.douyu.com'),
          Cookie(
              name: 'acf_auth',
              value: 'synthetic-session',
              domain: '.douyu.com'),
        ];
    await readyForCollection(tester);
    // No account service is registered: collection succeeds, import cannot.
    await tester.tap(find.text('完成登录'));
    await tester.pump();
    expect(find.text('凭据已读取，但未能导入账号，请重试。'), findsOneWidget);
    expect(find.textContaining('synthetic-'), findsNothing);
    expect(find.textContaining('无法读取'), findsNothing);
    expect(canComplete(tester), isTrue);
  });

  testWidgets('missing session remains a distinct recoverable result',
      (tester) async {
    platform.readCookies = (_) async => [
          Cookie(name: '', value: 'synthetic-nameless', domain: '.douyu.com'),
          Cookie(name: 'acf_uid', value: '123', domain: '.douyu.com'),
        ];
    await readyForCollection(tester);
    await tester.tap(find.text('完成登录'));
    await tester.pump();
    expect(find.textContaining('尚未读取到可导入的账号凭据'), findsOneWidget);
    expect(find.textContaining('无法读取'), findsNothing);
    expect(canComplete(tester), isTrue);
  });

  testWidgets('read completing after page disposal cannot import an account',
      (tester) async {
    final accounts = _CountingAccountManager();
    Get.put<PlatformAccountManager>(accounts);
    final pending = Completer<List<Cookie>>();
    platform.readCookies = (_) => pending.future;
    await readyForCollection(tester);
    await tester.tap(find.text('完成登录'));
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    expect(accounts.importCalls, 0);
    pending.complete([
      Cookie(name: 'acf_auth', value: 'synthetic-late', domain: '.douyu.com'),
    ]);
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(accounts.importCalls, 0);
  });

  testWidgets(
      'native creation without callback times out and retry recreates view',
      (tester) async {
    await mount(tester);
    final old = platform.views.single.params;
    expect(old.initialUrlRequest, isNull);
    expect(canComplete(tester), isFalse);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    await tester.pump(const Duration(seconds: 31));
    expect(find.textContaining('组件启动超时'), findsOneWidget);
    expect(find.byType(InAppWebView), findsNothing);
    expect(canComplete(tester), isFalse);
    await tester.tap(find.text('重试打开官网'));
    await tester.pump();
    await tester.pump();
    expect(platform.views, hasLength(2));
    old.onWebViewCreated!(controller);
    old.onLoadStop!(controller, official);
    await tester.pump();
    expect(nativeController.urls, isEmpty);
    expect(canComplete(tester), isFalse);
    platform.views.last.params.onWebViewCreated!(controller);
    await tester.pump();
    expect(nativeController.urls.single.toString(), official.toString());
    platform.views.last.params.onLoadStop!(controller, official);
    await tester.pump();
    expect(canComplete(tester), isTrue);
  });

  testWidgets(
      'completion requires official load, not creation or blank document',
      (tester) async {
    await mount(tester);
    final callbacks = platform.views.single.params;
    callbacks.onWebViewCreated!(controller);
    await tester.pump();
    callbacks.onLoadStop!(controller, WebUri('about:blank'));
    callbacks.onLoadStart!(controller, official);
    await tester.pump();
    expect(canComplete(tester), isFalse);
    callbacks.onLoadStop!(controller, official);
    await tester.pump();
    expect(canComplete(tester), isTrue);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    await tester.pump(const Duration(seconds: 31));
    expect(find.text('重试打开官网'), findsNothing);
    expect(platform.views, hasLength(1));
  });

  testWidgets('navigation without completion has a visible timeout',
      (tester) async {
    await mount(tester);
    final callbacks = platform.views.single.params;
    callbacks.onWebViewCreated!(controller);
    await tester.pump();
    callbacks.onLoadStart!(controller, official);
    await tester.pump(const Duration(seconds: 20));
    callbacks.onLoadStart!(controller, WebUri('https://passport.douyu.com/'));
    await tester.pump(const Duration(seconds: 11));
    expect(find.textContaining('官方页面加载超时'), findsOneWidget);
    expect(canComplete(tester), isFalse);
    callbacks.onLoadStop!(controller, official);
    await tester.pump();
    expect(canComplete(tester), isFalse);
  });

  testWidgets('environment failure is visible and can be retried',
      (tester) async {
    var attempt = 0;
    await mount(tester, prepare: () async {
      if (++attempt == 1) {
        throw const PlatformWebLoginEnvironmentException('无法初始化网页登录组件');
      }
      return null;
    });
    expect(find.text('无法初始化网页登录组件'), findsOneWidget);
    expect(canComplete(tester), isFalse);
    expect(platform.views, isEmpty);
    await tester.tap(find.text('重试打开官网'));
    await tester.pump();
    await tester.pump();
    expect(platform.views, hasLength(1));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('load command error does not expose native data', (tester) async {
    await mount(tester);
    nativeController.failLoad = true;
    platform.views.single.params.onWebViewCreated!(controller);
    await tester.pump();
    expect(find.textContaining('无法打开平台官方网站'), findsOneWidget);
    expect(find.textContaining('synthetic private'), findsNothing);
    expect(canComplete(tester), isFalse);
  });

  testWidgets('late environment callback after disposal does not create a view',
      (tester) async {
    final pending = Completer<WebViewEnvironment?>();
    await mount(tester, prepare: () => pending.future);
    await tester.pumpWidget(const SizedBox());
    pending.complete(null);
    await tester.pump();
    expect(platform.views, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('offsite page cannot enable completion or expose URL query',
      (tester) async {
    await mount(tester);
    final callbacks = platform.views.single.params;
    callbacks.onWebViewCreated!(controller);
    callbacks.onLoadStop!(controller,
        WebUri('https://douyu.com.attacker.invalid/?token=synthetic-private'));
    await tester.pump();
    expect(canComplete(tester), isFalse);
    expect(find.textContaining('已阻止离开平台官方网站'), findsOneWidget);
    expect(find.textContaining('synthetic-private'), findsNothing);
  });

  testWidgets('blocked navigation cancellation preserves the official page',
      (tester) async {
    await mount(tester);
    final callbacks = platform.views.single.params;
    callbacks.onWebViewCreated!(controller);
    callbacks.onLoadStop!(controller, official);
    await tester.pump();
    final external = WebUri('https://external.invalid/');
    expect(
        await callbacks.shouldOverrideUrlLoading!(
            controller,
            NavigationAction(
                isForMainFrame: true, request: URLRequest(url: external))),
        NavigationActionPolicy.CANCEL);
    callbacks.onReceivedError!(
        controller,
        WebResourceRequest(url: external, isForMainFrame: true),
        WebResourceError(
            type: WebResourceErrorType.CANCELLED, description: ''));
    await tester.pump();
    expect(canComplete(tester), isTrue);
    expect(find.byType(InAppWebView), findsOneWidget);
    // Genuine main document errors must still show the recovery UI.
    callbacks.onReceivedError!(
        controller,
        WebResourceRequest(url: official, isForMainFrame: true),
        WebResourceError(type: WebResourceErrorType.TIMEOUT, description: ''));
    await tester.pump();
    expect(canComplete(tester), isFalse);
    expect(find.textContaining('官方页面加载失败'), findsOneWidget);
  });
}
