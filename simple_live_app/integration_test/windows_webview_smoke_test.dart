import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:simple_live_app/modules/mine/account/platform_web_login_environment.dart';

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

    // Exercise the exact environment creation path used by account login.
    final environment = await preparePlatformWebLoginEnvironment();
    expect(environment, isNotNull);
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
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 300));
    }
    report['stage'] = 'passed';
    // The production helper owns the environment for the application lifetime.
  }, timeout: const Timeout(Duration(minutes: 3)));
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
