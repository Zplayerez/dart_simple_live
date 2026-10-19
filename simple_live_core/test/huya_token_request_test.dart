import 'dart:async';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:simple_live_core/simple_live_core.dart';
import 'package:test/test.dart';

class _BlockedTokenServer implements HttpClientAdapter {
  final started = Completer<void>();
  final cancelled = Completer<void>();
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? stream,
    Future<void>? cancelFuture,
  ) {
    started.complete();
    cancelFuture?.then((_) => cancelled.complete());
    return Completer<ResponseBody>().future;
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  test('TARS timeout uses milliseconds and bounds every transport phase', () {
    final site = HuyaSite();
    final options = site.tupClient.dio.options;
    expect(options.connectTimeout, const Duration(seconds: 60));
    expect(options.receiveTimeout, const Duration(seconds: 60));
    expect(options.sendTimeout, const Duration(seconds: 60));
    site.tupClient.dio.close(force: true);
  });

  test(
    'closing playback cancels the independent Huya TARS transport',
    () async {
      final site = HuyaSite();
      final server = _BlockedTokenServer();
      site.tupClient.dio.httpClientAdapter = server;
      final scope = HttpRequestScope();
      final result = scope.run(
        () => site.getCndTokenInfoEx('synthetic-stream'),
      );
      final assertion = expectLater(
        result,
        throwsA(isA<HttpRequestCancelled>()),
      );
      await server.started.future.timeout(const Duration(seconds: 2));
      scope.cancel();
      await assertion;
      await server.cancelled.future.timeout(const Duration(seconds: 2));
      expect(
        site.tupClient.dio.options.headers,
        isNot(contains('content-length')),
      );
      site.tupClient.dio.close(force: true);
    },
  );
}
