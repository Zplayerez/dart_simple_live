import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:simple_live_app/app/log.dart';

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
  final void Function(String) _diagnosticLog;

  Future<WebViewEnvironment>? _nativeInitialization;
  Future<WebViewEnvironment>? _boundedInitialization;

  WindowsPlatformWebLoginEnvironment({
    Future<String?> Function()? getAvailableVersion,
    Future<Directory> Function()? getSupportDirectory,
    Future<WebViewEnvironment> Function(WebViewEnvironmentSettings)?
        createEnvironment,
    this.initializationTimeout = const Duration(seconds: 15),
    void Function(String)? diagnosticLog,
  })  : _getAvailableVersion =
            getAvailableVersion ?? WebViewEnvironment.getAvailableVersion,
        _getSupportDirectory =
            getSupportDirectory ?? getApplicationSupportDirectory,
        _createEnvironment = createEnvironment ??
            ((settings) => WebViewEnvironment.create(settings: settings)),
        _diagnosticLog = diagnosticLog ?? Log.writeLog;

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
          _diagnosticLog('WebLogin initialization result=timeout');
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
    var stage = 'runtime';
    try {
      final version = await _getAvailableVersion();
      if (version == null || version.trim().isEmpty) {
        _diagnosticLog('WebLogin stage=runtime result=missing');
        throw const PlatformWebLoginEnvironmentException(
            '未检测到 Microsoft Edge WebView2 Runtime，请安装后重试，或使用 Cookie 导入。');
      }
      stage = 'support_directory';
      final supportDirectory = await _getSupportDirectory();
      final profile =
          Directory(path.join(supportDirectory.path, 'WebView2')).absolute;
      stage = 'profile_directory';
      await profile.create(recursive: true);
      stage = 'native_environment';
      final environment = await _createEnvironment(
          WebViewEnvironmentSettings(userDataFolder: profile.path));
      _diagnosticLog('WebLogin stage=native_environment result=ready');
      return environment;
    } on PlatformWebLoginEnvironmentException {
      rethrow;
    } catch (error) {
      // Never log native messages, details, stack traces, settings or paths.
      // The Windows build forwards only the numeric HRESULT in exception.code.
      final String kind;
      String? code;
      if (error is PlatformException) {
        kind = 'platform';
        if (RegExp(r'^-?[0-9]{1,10}$').hasMatch(error.code)) {
          final value = int.tryParse(error.code);
          if (value != null && value >= -0x80000000 && value <= 0xffffffff) {
            code =
                '0x${value.toUnsigned(32).toRadixString(16).padLeft(8, '0')}';
          }
        }
      } else if (error is FileSystemException) {
        kind = 'filesystem';
        code = error.osError?.errorCode.toString();
      } else if (error is MissingPluginException) {
        kind = 'missing_plugin';
      } else {
        kind = 'unexpected';
      }
      _diagnosticLog('WebLogin stage=$stage result=failed kind=$kind'
          '${code == null ? '' : ' code=$code'}');
      final message = switch (code) {
        '0x80070005' => '系统拒绝访问网页登录组件，请检查目录权限或安全软件后重试。',
        '0x8007139f' => '网页登录组件配置冲突，请从托盘完全退出 App 后重试。',
        '0x80010106' || '0x800401f0' => '网页登录组件运行环境异常，请从托盘完全退出 App 后重试。',
        _ when stage == 'support_directory' || stage == 'profile_directory' =>
          '无法准备网页登录数据目录，请检查当前用户的目录写入权限后重试。',
        _ => '无法初始化网页登录组件，请先重试；若仍失败，请从托盘完全退出 App 后重新打开。',
      };
      throw PlatformWebLoginEnvironmentException(message);
    }
  }
}
