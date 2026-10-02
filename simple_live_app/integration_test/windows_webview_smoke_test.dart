import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:simple_live_app/modules/mine/account/platform_web_login_environment.dart';
import 'package:simple_live_app/modules/mine/account/platform_web_login_policy.dart';
import 'package:simple_live_core/simple_live_core.dart';

const _html = '''
<!doctype html>
<html><head><meta charset="utf-8">
<meta http-equiv="Content-Security-Policy"
      content="default-src 'none'; style-src 'unsafe-inline'">
<style>
html, body { margin: 0; min-height: 100%; background: #17354a; }
body { padding: 32px; box-sizing: border-box; color: white; font: 20px sans-serif; }
h1 { background: #ffd166; color: #17354a; padding: 24px; max-width: 500px; }
</style></head>
<body><h1 id="smoke-marker">Local WebView2 smoke test</h1>
<p>No platform login or external resource is used.</p></body></html>
''';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Windows WebView renders and reopens with the shared environment',
      (tester) async {
    final captures = <Map<String, dynamic>>[];
    final report = <String, dynamic>{
      'platform': Platform.operatingSystem,
      'stage': 'initializing',
      'captures': captures,
    };
    binding.reportData = report;
    expect(Platform.isWindows, isTrue,
        reason: 'Run this native smoke test with flutter drive -d windows.');

    // Keep even local test runs away from the installed app's login profile.
    // Only path resolution is replaced; environment creation stays native.
    final previousPathProvider = PathProviderPlatform.instance;
    final supportDirectory =
        await Directory.systemTemp.createTemp('simple-live-webview-smoke-');
    PathProviderPlatform.instance = _SmokePathProvider(supportDirectory.path);
    addTearDown(() async {
      PathProviderPlatform.instance = previousPathProvider;
      try {
        await supportDirectory.delete(recursive: true);
      } on FileSystemException {
        // The app-lifetime native environment may keep its temporary files
        // locked until this test process exits. Fixture cookies are removed
        // separately through the native CookieManager below.
      }
    });
    report['isolatedProfile'] = true;

    // Exercise the exact environment creation path used by account login.
    final environment = await preparePlatformWebLoginEnvironment();
    expect(environment, isNotNull);
    expect(
        environment!.settings?.userDataFolder ==
            Directory(
                    '${supportDirectory.path}${Platform.pathSeparator}WebView2')
                .absolute
                .path,
        isTrue,
        reason: 'Native smoke must use the isolated temporary profile.');
    report['environmentCreated'] = true;

    for (final name in ['initial', 'reopened']) {
      expect(await preparePlatformWebLoginEnvironment(), same(environment));
      final capture = <String, dynamic>{'name': name};
      captures.add(capture);
      report['stage'] = '$name: creating native view';
      InAppWebViewController? controller;
      var loadDataFinished = false;
      var loadStops = 0;
      final loadErrors = <String>[];
      capture['loadErrors'] = loadErrors;

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: InAppWebView(
            key: ValueKey(name),
            webViewEnvironment: environment,
            initialSettings: InAppWebViewSettings(javaScriptEnabled: true),
            onWebViewCreated: (value) async {
              controller = value;
              capture['nativeViewCreated'] = true;
              // Match login: the Windows plugin must subscribe its controller
              // channel before navigation can start emitting native events.
              try {
                await value
                    .loadData(data: _html)
                    .timeout(const Duration(seconds: 5));
                capture['loadDataCompleted'] = true;
              } catch (error) {
                loadErrors.add('loadData: ${error.runtimeType}');
              } finally {
                loadDataFinished = true;
              }
            },
            onLoadStop: (_, __) {
              loadStops++;
              capture['loadStops'] = loadStops;
            },
            onReceivedError: (_, request, error) {
              loadErrors.add(error.type.toString());
            },
          ),
        ),
      ));
      await _waitFor(tester, () => controller != null, 'native view creation');
      final webView = controller!;
      report['stage'] = '$name: loading local HTML';
      await _waitFor(tester, () => loadDataFinished, 'local HTML submission');
      expect(loadErrors, isEmpty);
      await _waitFor(tester, () => loadStops > 0 || loadErrors.isNotEmpty,
          'native load completion');
      expect(loadErrors, isEmpty);
      await _waitFor(
        tester,
        () async => await webView.evaluateJavascript(source: '''
document.readyState === 'complete' &&
document.getElementById('smoke-marker') !== null
''').timeout(const Duration(seconds: 5)) == true,
        'local document readiness',
      );
      expect(loadErrors, isEmpty);

      report['stage'] = '$name: executing JavaScript';
      final dom = await webView.evaluateJavascript(source: '''
(() => {
  const marker = document.getElementById('smoke-marker');
  marker.textContent = 'JavaScript verified';
  return { text: marker.textContent, width: innerWidth, height: innerHeight };
})()
''').timeout(const Duration(seconds: 5));
      expect(dom, isA<Map>());
      expect(dom['text'], 'JavaScript verified');
      expect(dom['width'], greaterThan(100));
      expect(dom['height'], greaterThan(100));
      capture['javascript'] = dom;
      await tester.pump(const Duration(milliseconds: 300));

      report['stage'] = '$name: capturing renderer';
      final screenshot =
          await webView.takeScreenshot().timeout(const Duration(seconds: 10));
      expect(screenshot, isNotNull);
      capture['pngBase64'] = base64Encode(screenshot!);
      final codec = await ui.instantiateImageCodec(screenshot);
      final frame = await codec.getNextFrame();
      try {
        final pixels = await frame.image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        );
        expect(pixels, isNotNull);
        var bluePixels = 0;
        var yellowPixels = 0;
        // A blank screenshot must fail even when DOM JavaScript succeeds.
        for (var offset = 0; offset < pixels!.lengthInBytes; offset += 64) {
          final r = pixels.getUint8(offset);
          final g = pixels.getUint8(offset + 1);
          final b = pixels.getUint8(offset + 2);
          if (r == 0x17 && g == 0x35 && b == 0x4a) bluePixels++;
          if (r == 0xff && g == 0xd1 && b == 0x66) yellowPixels++;
        }
        capture['renderedPixels'] = {
          'width': frame.image.width,
          'height': frame.image.height,
          'blueSamples': bluePixels,
          'yellowSamples': yellowPixels,
        };
        expect(bluePixels, greaterThan(100));
        expect(yellowPixels, greaterThan(100));
      } finally {
        frame.image.dispose();
        codec.dispose();
      }
      if (name == 'reopened') {
        report['stage'] = 'checking native account Cookie collection';
        await _checkNativeAccountCookies(environment, webView, report);
      }
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 300));
    }
    report['stage'] = 'passed';
    // The production helper owns the environment for the application lifetime.
  }, timeout: const Timeout(Duration(minutes: 3)));
}

class _SmokePathProvider extends PathProviderPlatform {
  _SmokePathProvider(this.supportPath);

  final String supportPath;

  @override
  Future<String?> getApplicationSupportPath() async => supportPath;
}

Future<void> _checkNativeAccountCookies(WebViewEnvironment environment,
    InAppWebViewController visibleWebView, Map<String, dynamic> report) async {
  final manager = CookieManager.instance(webViewEnvironment: environment);
  final result = <String, dynamic>{};
  report['nativeAccountCookies'] = result;
  const fixtureNames = {
    'huya.com': [
      'yyuid',
      'udb_anouid',
      'udb_anobiztoken',
      'udb_uid',
      'udb_biztoken',
    ],
    'douyu.com': ['udb_uid', 'udb_biztoken'],
  };

  Future<String?> collect(String siteId) => collectOfficialAccountCookieHeader(
        siteId,
        readCookies: (uri) async {
          // Native jar operations only: no page navigation or HTTP request.
          final cookies = await manager
              .getCookies(url: WebUri(uri.toString()))
              .timeout(const Duration(seconds: 5));
          return cookies
              .map((cookie) => OfficialWebCookie(
                    name: cookie.name,
                    value: cookie.value,
                    domain: cookie.domain,
                  ))
              .toList();
        },
      );

  Future<void> put(String root, String name) async {
    // Write through the visible login view, then collect through the separate
    // native CookieManager to prove they share the same browser profile.
    dynamic stored;
    try {
      stored = await visibleWebView.callDevToolsProtocolMethod(
        methodName: 'Network.setCookie',
        parameters: {
          'url': 'https://www.$root/',
          'domain': '.$root',
          'path': '/',
          'name': name,
          'value': name.endsWith('biztoken')
              ? 'native-smoke-only-token'
              : '123456789',
          'secure': true,
          'httpOnly': true,
        },
      ).timeout(const Duration(seconds: 5));
    } catch (_) {
      throw StateError('Native fixture Cookie write failed.');
    }
    expect(stored is Map && stored['success'] == true, isTrue,
        reason: 'Native fixture Cookie write failed.');
  }

  try {
    await put('huya.com', 'yyuid');
    expect(await collect('huya') == null, isTrue,
        reason: 'A public Huya user ID must not count as a login session.');
    result['publicUidRejected'] = true;

    await put('huya.com', 'udb_anouid');
    await put('huya.com', 'udb_anobiztoken');
    expect(await collect('huya') == null, isTrue,
        reason: 'Huya visitor cookies must not count as an account session.');
    result['visitorPairRejected'] = true;

    await put('huya.com', 'udb_uid');
    expect(await collect('huya') == null, isTrue,
        reason: 'A modern Huya UID without its token must be rejected.');
    result['missingTokenRejected'] = true;

    await put('douyu.com', 'udb_biztoken');
    expect(await collect('huya') == null, isTrue,
        reason: 'Another platform token must not complete the Huya pair.');
    result['otherPlatformTokenExcluded'] = true;

    await put('douyu.com', 'udb_uid');
    expect(await collect('douyu') == null, isTrue,
        reason: 'Huya Cookie names must not establish a Douyu session.');
    result['otherPlatformCandidateRejected'] = true;

    await put('huya.com', 'udb_biztoken');
    final header = await collect('huya');
    // Assert only booleans so a failure never prints Cookie/header values.
    expect(header != null, isTrue,
        reason: 'The native modern Huya pair must be collected.');
    final parsed = PlatformCookie.parse(header!);
    expect(parsed.hasAccountSessionFor(LiveAccountPlatform.huya), isTrue);
    expect(parsed.values.containsKey('udb_l'), isFalse);
    expect(parsed.values.containsKey('udb_uid'), isTrue);
    expect(parsed.values.containsKey('udb_biztoken'), isTrue);

    final nativeCookies = await manager
        .getCookies(url: WebUri('https://i.huya.com/'))
        .timeout(const Duration(seconds: 5));
    final modernPair = nativeCookies
        .where((cookie) =>
            cookie.name == 'udb_uid' || cookie.name == 'udb_biztoken')
        .toList();
    expect(modernPair.length, 2);
    expect(
        modernPair.every((cookie) =>
            cookie.isHttpOnly == true &&
            cookie.isSecure == true &&
            cookie.path == '/' &&
            cookie.domain == '.huya.com'),
        isTrue);
    result['modernHttpOnlyPairAccepted'] = true;
    result['modernPairCookieCount'] = modernPair.length;
  } finally {
    // Delete only the fixture names at their exact domain/path, including
    // partial setup. Never clear a whole browser jar.
    for (final entry in fixtureNames.entries) {
      for (final name in entry.value) {
        await manager
            .deleteCookie(
              url: WebUri('https://www.${entry.key}/'),
              domain: '.${entry.key}',
              path: '/',
              name: name,
            )
            .timeout(const Duration(seconds: 5));
      }
      final remaining = await manager
          .getCookies(url: WebUri('https://www.${entry.key}/'))
          .timeout(const Duration(seconds: 5));
      expect(
          remaining.any((cookie) => entry.value.contains(cookie.name)), isFalse,
          reason: 'Native fixture Cookies must be removed after the test.');
    }
    result['fixtureCookiesRemoved'] = true;
  }
}

Future<void> _waitFor(WidgetTester tester, FutureOr<bool> Function() ready,
    String operation) async {
  final elapsed = Stopwatch()..start();
  while (!await ready()) {
    if (elapsed.elapsed > const Duration(seconds: 20)) {
      fail('Timed out waiting for $operation.');
    }
    await tester.pump(const Duration(milliseconds: 100));
  }
}
