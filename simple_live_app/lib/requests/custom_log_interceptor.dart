import 'package:dio/dio.dart';
import 'package:simple_live_core/simple_live_core.dart';
import 'package:simple_live_app/app/log.dart';

/// Account responses can contain credentials even outside named Cookie fields.
/// Diagnostics retain request timing/status without bodies or authentication data.
class CustomLogInterceptor extends Interceptor {
  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    options.extra['ts'] = DateTime.now().millisecondsSinceEpoch;
    super.onRequest(options, handler);
  }

  int _elapsed(RequestOptions options) =>
      DateTime.now().millisecondsSinceEpoch -
      (options.extra['ts'] as int? ?? DateTime.now().millisecondsSinceEpoch);

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    Log.e(
        '[HTTP Error] ${err.type} [${err.response?.statusCode}] '
        '[${_elapsed(err.requestOptions)}ms] ${err.requestOptions.method} '
        '${LogRedactor.redactUri(err.requestOptions.uri)}',
        err.stackTrace);
    super.onError(err, handler);
  }

  @override
  void onResponse(Response response, ResponseInterceptorHandler handler) {
    Log.i('[HTTP Response] [${response.statusCode}] '
        '[${_elapsed(response.requestOptions)}ms] ${response.requestOptions.method} '
        '${LogRedactor.redactUri(response.requestOptions.uri)}');
    super.onResponse(response, handler);
  }
}
