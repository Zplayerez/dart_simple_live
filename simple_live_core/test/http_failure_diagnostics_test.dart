import 'dart:io';
import 'package:dio/dio.dart';
import 'package:simple_live_core/simple_live_core.dart';
import 'package:simple_live_core/src/common/core_error.dart';
import 'package:simple_live_core/src/common/custom_interceptor.dart';
import 'package:simple_live_core/src/common/http_client.dart' as core;
import 'package:test/test.dart';

void main() {
  test(
    'HTTP failure keeps safe category without logging exception secrets',
    () async {
      final previous = core.HttpClient.instance.dio;
      final oldLog = CoreLog.onPrintLog;
      final messages = <String>[];
      CoreLog.onPrintLog = (_, text) => messages.add(text);
      final dio = Dio()
        ..interceptors.addAll([
          InterceptorsWrapper(
            onRequest: (request, handler) {
              handler.reject(
                DioException(
                  requestOptions: request,
                  type: DioExceptionType.connectionError,
                  error: const SocketException(
                    'Failed host lookup synthetic-secret',
                    osError: OSError('synthetic-private-value', 11001),
                  ),
                ),
                true,
              );
            },
          ),
          CustomInterceptor(),
        ]);
      core.HttpClient.instance.dio = dio;
      try {
        await expectLater(
          core.HttpClient.instance.getText(
            'https://fixture.invalid/private-path?cookie=synthetic-cookie',
          ),
          throwsA(
            isA<CoreError>().having((e) => e.category, 'category', 'dns'),
          ),
        );
        expect(messages.join(), contains('cause=dns osCode=11001'));
        expect(messages.join(), isNot(contains('synthetic-')));
        expect(messages.join(), isNot(contains('private-path')));
      } finally {
        dio.close(force: true);
        core.HttpClient.instance.dio = previous;
        CoreLog.onPrintLog = oldLog;
      }
    },
  );
}
