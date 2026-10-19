import 'dart:async';
import 'package:dio/dio.dart';

class HttpRequestCancelled implements Exception {
  const HttpRequestCancelled();
  @override
  String toString() => '播放请求已取消';
}

/// A deadline for the complete provider operation, including sequential calls.
/// The zone keeps concurrent room/account/background requests independent.
class HttpRequestScope {
  static final _zoneKey = Object();
  static HttpRequestScope? get current => Zone.current[_zoneKey];
  final Duration timeout;
  final _token = CancelToken();
  final _aborted = Completer<Object>();
  bool _started = false;
  bool _closed = false;
  Object? _error;

  HttpRequestScope({this.timeout = const Duration(seconds: 8)});

  bool get active => !_closed && _error == null;

  void check() {
    if (!active) throw _error ?? const HttpRequestCancelled();
  }

  void cancel([Object reason = const HttpRequestCancelled()]) {
    if (!active) return;
    _error = reason;
    _aborted.complete(reason);
    _token.cancel('playback-request-cancelled');
  }

  CancelToken tokenFor(CancelToken? caller) {
    check();
    if (caller == null) return _token;
    // Retain both the caller's cancellation and the operation deadline.
    final child = CancelToken();
    if (caller.isCancelled) child.cancel('caller-cancelled');
    caller.whenCancel.then((_) => child.cancel('caller-cancelled'));
    _token.whenCancel.then((_) => child.cancel('playback-request-cancelled'));
    return child;
  }

  Future<T> run<T>(Future<T> Function() operation) async {
    if (_started) throw StateError('HttpRequestScope is single-use');
    _started = true;
    check();
    final parent = current;
    parent?.check();
    parent?._token.whenCancel.then((_) => cancel());
    final timer = Timer(
      timeout,
      () => cancel(TimeoutException('获取播放信息超时', timeout)),
    );
    try {
      return await runZoned(
        () => Future.any<T>([
          Future<T>.sync(operation),
          _aborted.future.then<T>((error) => throw error),
        ]),
        zoneValues: {_zoneKey: this},
      );
    } finally {
      timer.cancel();
      _closed = true;
      // Also stop unfinished alternatives and reject late fallback requests.
      _token.cancel('playback-request-finished');
    }
  }
}
