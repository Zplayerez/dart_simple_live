import 'dart:async';
import 'dart:io';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

class PlatformWebLoginEnvironmentException implements Exception {
  final String message;

  const PlatformWebLoginEnvironmentException(this.message);

  @override
  String toString() => message;
}

final _windowsEnvironment = WindowsPlatformWebLoginEnvironment();

/// Login, CookieManager and logout must all use this same Windows profile.
/// Keep it alive for the application lifetime, including between login pages.
Future<WebViewEnvironment?> preparePlatformWebLoginEnvironment() async {
  PlatformInAppWebViewController.debugLoggingSettings.enabled = false;
  PlatformWebViewEnvironment.debugLoggingSettings.enabled = false;
  if (!Platform.isWindows) return null;
  return _windowsEnvironment.prepare();
}

/// Owns a single native initialization, with injectable platform operations for
/// testing failures and delayed completions without a Windows desktop.
class WindowsPlatformWebLoginEnvironment {
  final Future<String?> Function() _getAvailableVersion;
  final Future<Directory> Function() _getSupportDirectory;
  final Future<WebViewEnvironment> Function(WebViewEnvironmentSettings)
      _createEnvironment;
  final Duration initializationTimeout;

  Future<WebViewEnvironment>? _nativeInitialization;
  Future<WebViewEnvironment>? _boundedInitialization;

  WindowsPlatformWebLoginEnvironment({
    Future<String?> Function()? getAvailableVersion,
    Future<Directory> Function()? getSupportDirectory,
    Future<WebViewEnvironment> Function(WebViewEnvironmentSettings)?
        createEnvironment,
    this.initializationTimeout = const Duration(seconds: 15),
  })  : _getAvailableVersion =
            getAvailableVersion ?? WebViewEnvironment.getAvailableVersion,
        _getSupportDirectory =
            getSupportDirectory ?? getApplicationSupportDirectory,
        _createEnvironment = createEnvironment ??
            ((settings) => WebViewEnvironment.create(settings: settings));

  Future<WebViewEnvironment> prepare() {
    final existing = _boundedInitialization;
    if (existing != null) return existing;

    // A timeout cannot cancel native WebView2 creation. Retain that operation
    // so retry waits for it instead of creating overlapping environments. A
    // real failure clears it; a late success remains cached for the next retry.
    final native = _nativeInitialization ?? _startNativeInitialization();
    late final Future<WebViewEnvironment> bounded;
    bounded = native.timeout(initializationTimeout).onError<Object>(
      (error, stack) {
        if (identical(_boundedInitialization, bounded)) {
          _boundedInitialization = null;
        }
        if (error is PlatformWebLoginEnvironmentException) throw error;
        if (error is TimeoutException) {
          throw const PlatformWebLoginEnvironmentException(
              '网页登录组件初始化超时，请重试或使用 Cookie 导入。');
        }
        // Native errors may include a local profile path. Never display or log
        // the original exception, browser settings or authorization data.
        throw const PlatformWebLoginEnvironmentException(
            '无法初始化网页登录组件，请重试或使用 Cookie 导入。');
      },
    );
    _boundedInitialization = bounded;
    return bounded;
  }

  Future<WebViewEnvironment> _startNativeInitialization() {
    late final Future<WebViewEnvironment> native;
    native = _create().onError<Object>((error, stack) {
      if (identical(_nativeInitialization, native)) {
        _nativeInitialization = null;
      }
      Error.throwWithStackTrace(error, stack);
    });
    _nativeInitialization = native;
    return native;
  }

  Future<WebViewEnvironment> _create() async {
    final version = await _getAvailableVersion();
    if (version == null || version.trim().isEmpty) {
      throw const PlatformWebLoginEnvironmentException(
          '未检测到 Microsoft Edge WebView2 Runtime，请安装后重试，或使用 Cookie 导入。');
    }
    final supportDirectory = await _getSupportDirectory();
    final profile =
        Directory(path.join(supportDirectory.path, 'WebView2')).absolute;
    await profile.create(recursive: true);
    return _createEnvironment(
        WebViewEnvironmentSettings(userDataFolder: profile.path));
  }
}
