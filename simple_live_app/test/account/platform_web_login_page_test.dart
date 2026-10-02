import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
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
  @override
  PlatformInAppWebViewWidget createPlatformInAppWebViewWidget(
      PlatformInAppWebViewWidgetCreationParams params) {
    final view = _View(params);
    views.add(view);
    return view;
  }
}

void main() {
  late _WebPlatform platform;
  late _Controller nativeController;
  late InAppWebViewController controller;
  final official = WebUri('https://www.douyu.com/');

  setUp(() {
    platform = _WebPlatform();
    InAppWebViewPlatform.instance = platform;
    nativeController = _Controller();
    controller =
        InAppWebViewController.fromPlatform(platform: nativeController);
  });

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
