import 'dart:io';
import 'package:dio/dio.dart';

/// Allowlisted diagnostics only. Exception messages can embed credentials.
class HttpFailure {
  final String category;
  final int? osCode;
  const HttpFailure(this.category, [this.osCode]);

  static HttpFailure from(DioException error) {
    final cause = error.error;
    final code = cause is SocketException ? cause.osError?.errorCode : null;
    switch (error.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.sendTimeout:
        return HttpFailure('timeout', code);
      case DioExceptionType.cancel:
        return const HttpFailure('cancelled');
      case DioExceptionType.badCertificate:
        return const HttpFailure('tls');
      case DioExceptionType.badResponse:
        return const HttpFailure('http');
      default:
        break;
    }
    if (cause is HandshakeException || cause is TlsException) {
      return HttpFailure('tls', code);
    }
    final text = (cause is SocketException ? cause.message : cause.toString())
        .toLowerCase();
    if (text.contains('host lookup') ||
        text.contains('name resolution') ||
        text.contains('resolve host') ||
        text.contains('no such host') ||
        const [11001, 11002, 11003, 11004].contains(code)) {
      return HttpFailure('dns', code);
    }
    if (text.contains('connection refused')) {
      return HttpFailure('connection-refused', code);
    }
    if (text.contains('connection reset')) {
      return HttpFailure('connection-reset', code);
    }
    if (text.contains('unreachable') || text.contains('no route to host')) {
      return HttpFailure('network-unreachable', code);
    }
    return HttpFailure('connection', code);
  }
}
