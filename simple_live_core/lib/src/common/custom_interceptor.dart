import 'package:dio/dio.dart';
import 'core_log.dart';
import 'sensitive_log.dart';

/// Request/response content may contain credentials under arbitrary field names.
/// Even verbose mode only records transport metadata.
class CustomInterceptor extends Interceptor {
  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    options.extra['ts'] = DateTime.now().millisecondsSinceEpoch;
    if (CoreLog.requestLogType != RequestLogType.none) {
      CoreLog.i(
        '[HTTP Request] [${options.method}] ${LogRedactor.redactUri(options.uri)}',
      );
    }
    super.onRequest(options, handler);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    if (CoreLog.requestLogType != RequestLogType.none) {
      CoreLog.e(
        '[HTTP Error] [${err.type}] [${err.response?.statusCode}] '
        '[${err.requestOptions.method}] ${LogRedactor.redactUri(err.requestOptions.uri)}',
        err.stackTrace,
      );
    }
    super.onError(err, handler);
  }

  @override
  void onResponse(Response response, ResponseInterceptorHandler handler) {
    if (CoreLog.requestLogType != RequestLogType.none) {
      final started = response.requestOptions.extra['ts'] as int?;
      final elapsed = started == null
          ? 0
          : DateTime.now().millisecondsSinceEpoch - started;
      CoreLog.i(
        '[HTTP Response] [${response.statusCode}] [${elapsed}ms] '
        '[${response.requestOptions.method}] ${LogRedactor.redactUri(response.requestOptions.uri)}',
      );
    }
    super.onResponse(response, handler);
  }
}
