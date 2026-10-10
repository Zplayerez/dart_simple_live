import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:simple_live_app/modules/mine/account/platform_web_login_environment.dart';

class _TestEnvironment extends PlatformWebViewEnvironment {
  _TestEnvironment()
      : super.implementation(const PlatformWebViewEnvironmentCreationParams());

  @override
  String get id => 'synthetic-environment';
}

void main() {
  late Directory directory;
  late WebViewEnvironment environment;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('web-login-environment-');
    environment = WebViewEnvironment.fromPlatform(platform: _TestEnvironment());
  });

  tearDown(() async {
    await directory.delete(recursive: true);
  });

  test('concurrent callers share one environment in application support',
      () async {
    final created = Completer<WebViewEnvironment>();
    var calls = 0;
    final loader = WindowsPlatformWebLoginEnvironment(
      getAvailableVersion: () async => 'synthetic-runtime',
      getSupportDirectory: () async => directory,
      createEnvironment: (settings) {
        calls++;
        expect(settings.userDataFolder,
            path.join(directory.absolute.path, 'WebView2'));
        expect(Directory(settings.userDataFolder!).existsSync(), isTrue);
        return created.future;
      },
    );
    final first = loader.prepare();
    final concurrent = loader.prepare();
    expect(identical(first, concurrent), isTrue);
    created.complete(environment);
    expect(await first, same(environment));
    expect(await concurrent, same(environment));
    expect(await loader.prepare(), same(environment));
    expect(calls, 1);
  });

  test('missing runtime is actionable and a later retry can succeed', () async {
    String? version;
    var directoryCalls = 0;
    final loader = WindowsPlatformWebLoginEnvironment(
      getAvailableVersion: () async => version,
      getSupportDirectory: () async {
        directoryCalls++;
        return directory;
      },
      createEnvironment: (_) async => environment,
    );
    await expectLater(
      loader.prepare(),
      throwsA(isA<PlatformWebLoginEnvironmentException>()
          .having((error) => error.message, 'message', contains('安装'))),
    );
    expect(directoryCalls, 0);
    version = 'synthetic-runtime';
    expect(await loader.prepare(), same(environment));
    expect(directoryCalls, 1);
  });

  test('native failure is sanitized and does not poison retry', () async {
    var calls = 0;
    final diagnostics = <String>[];
    final loader = WindowsPlatformWebLoginEnvironment(
      diagnosticLog: diagnostics.add,
      getAvailableVersion: () async => 'synthetic-runtime',
      getSupportDirectory: () async => directory,
      createEnvironment: (_) async {
        calls++;
        if (calls == 1) {
          throw PlatformException(
              code: '0', message: 'private-profile-path synthetic-secret');
        }
        return environment;
      },
    );
    await expectLater(
      loader.prepare(),
      throwsA(isA<PlatformWebLoginEnvironmentException>().having(
          (error) => error.toString(),
          'message',
          allOf(contains('无法初始化'), isNot(contains('private-profile'))))),
    );
    expect(await loader.prepare(), same(environment));
    expect(calls, 2);
    expect(diagnostics, [
      'WebLogin stage=native_environment result=failed kind=platform code=0x00000000',
      'WebLogin stage=native_environment result=ready',
    ]);
  });

  test('native HRESULT is retained but native message and details are omitted',
      () async {
    final diagnostics = <String>[];
    final loader = WindowsPlatformWebLoginEnvironment(
      diagnosticLog: diagnostics.add,
      getAvailableVersion: () async => 'synthetic-runtime',
      getSupportDirectory: () async => directory,
      createEnvironment: (_) async => throw PlatformException(
        code: '2147947423', // HRESULT_FROM_WIN32(ERROR_INVALID_STATE)
        message: 'private-profile-path synthetic-secret',
        details: {'cookie': 'synthetic-secret'},
      ),
    );
    await expectLater(
      loader.prepare(),
      throwsA(isA<PlatformWebLoginEnvironmentException>()
          .having((error) => error.message, 'message', contains('配置冲突'))),
    );
    expect(diagnostics.single,
        'WebLogin stage=native_environment result=failed kind=platform code=0x8007139f');
  });

  test('untrusted platform error codes never reach diagnostics', () async {
    final diagnostics = <String>[];
    final loader = WindowsPlatformWebLoginEnvironment(
      diagnosticLog: diagnostics.add,
      getAvailableVersion: () async => throw PlatformException(
          code: 'private-profile-path synthetic-secret',
          message: 'synthetic-secret'),
      getSupportDirectory: () async => directory,
      createEnvironment: (_) async => environment,
    );
    await expectLater(
        loader.prepare(), throwsA(isA<PlatformWebLoginEnvironmentException>()));
    expect(diagnostics.single,
        'WebLogin stage=runtime result=failed kind=platform');
  });

  test('timeout retry reuses pending native creation and accepts late success',
      () async {
    final created = Completer<WebViewEnvironment>();
    var calls = 0;
    final loader = WindowsPlatformWebLoginEnvironment(
      getAvailableVersion: () async => 'synthetic-runtime',
      getSupportDirectory: () async => directory,
      createEnvironment: (_) {
        calls++;
        return created.future;
      },
      initializationTimeout: const Duration(milliseconds: 100),
    );
    await expectLater(
      loader.prepare(),
      throwsA(isA<PlatformWebLoginEnvironmentException>()
          .having((error) => error.message, 'message', contains('超时'))),
    );
    final retry = loader.prepare();
    expect(calls, 1);
    created.complete(environment);
    expect(await retry, same(environment));
    expect(await loader.prepare(), same(environment));
    expect(calls, 1);
  });

  test('late native failure after timeout permits one fresh initialization',
      () async {
    final created = Completer<WebViewEnvironment>();
    var calls = 0;
    final loader = WindowsPlatformWebLoginEnvironment(
      getAvailableVersion: () async => 'synthetic-runtime',
      getSupportDirectory: () async => directory,
      createEnvironment: (_) {
        calls++;
        return calls == 1 ? created.future : Future.value(environment);
      },
      initializationTimeout: const Duration(milliseconds: 100),
    );
    await expectLater(
        loader.prepare(), throwsA(isA<PlatformWebLoginEnvironmentException>()));
    final waitingRetry = loader.prepare();
    final observedFailure = expectLater(
        waitingRetry, throwsA(isA<PlatformWebLoginEnvironmentException>()));
    created.completeError(StateError('synthetic-delayed-failure'));
    await observedFailure;
    final fresh = loader.prepare();
    final concurrent = loader.prepare();
    expect(await fresh, same(environment));
    expect(await concurrent, same(environment));
    expect(calls, 2);
  });

  test('support directory failure is sanitized and retried', () async {
    var calls = 0;
    final loader = WindowsPlatformWebLoginEnvironment(
      getAvailableVersion: () async => 'synthetic-runtime',
      getSupportDirectory: () async {
        calls++;
        if (calls == 1) {
          throw const FileSystemException('private-profile-path');
        }
        return directory;
      },
      createEnvironment: (_) async => environment,
    );
    await expectLater(
      loader.prepare(),
      throwsA(isA<PlatformWebLoginEnvironmentException>().having(
          (error) => error.message,
          'message',
          isNot(contains('private-profile')))),
    );
    expect(await loader.prepare(), same(environment));
  });

  test('other operating systems do not initialize a Windows environment',
      () async {
    if (!Platform.isWindows) {
      expect(await preparePlatformWebLoginEnvironment(), isNull);
    }
  });
}
