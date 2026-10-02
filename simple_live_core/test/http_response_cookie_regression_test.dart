import 'package:dio/dio.dart';
import 'package:simple_live_core/simple_live_core.dart';
import 'package:simple_live_core/src/common/core_error.dart';
import 'package:simple_live_core/src/common/http_client.dart';
import 'package:test/test.dart';

void main() {
  late Dio original;
  late DouyinSite site;
  setUp(() {
    original = HttpClient.instance.dio;
    site = DouyinSite()
      ..cookie = 'sessionid=synthetic-account; ttwid=old-device';
  });
  tearDown(() {
    HttpClient.instance.dio.close();
    HttpClient.instance.dio = original;
  });

  Dio rejectingResponse(int status) {
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          expect(options.followRedirects, isFalse);
          handler.reject(
            DioException(
              requestOptions: options,
              type: DioExceptionType.badResponse,
              response: Response(
                requestOptions: options,
                statusCode: status,
                headers: Headers.fromMap({
                  'set-cookie': [
                    'ttwid=rotated-device; Domain=.douyin.com; Path=/; Secure',
                    'sessionid=foreign; Domain=.example.com; Path=/; Secure',
                  ],
                }),
                data: 'fixture',
              ),
            ),
          );
        },
      ),
    );
    return dio;
  }

  test(
    'HEAD 403 dispatches trusted cookies to current session and callback',
    () async {
      HttpClient.instance.dio = rejectingResponse(403);
      final updates = <LiveAccountSession>[];
      site.onAccountSessionUpdated = updates.add;
      final response = await HttpClient.instance.head(
        'https://live.douyin.com/123',
        header: await site.getRequestHeaders(),
      );
      expect(response.statusCode, 403);
      expect(site.accountSession!.cookie.values['ttwid'], 'rotated-device');
      expect(
        site.accountSession!.cookie.values['sessionid'],
        'synthetic-account',
      );
      expect(updates, hasLength(1));
      expect(
        (await site.getRequestHeaders())['cookie'],
        contains('ttwid=rotated-device'),
      );
    },
  );

  test(
    'failed JSON/text/POST preserve error semantics after cookie rotation',
    () async {
      HttpClient.instance.dio = rejectingResponse(401);
      for (final method in ['json', 'text', 'post']) {
        site.cookie = 'sessionid=synthetic-account; ttwid=old-device';
        final headers = await site.getRequestHeaders();
        final Future<dynamic> request;
        switch (method) {
          case 'json':
            request = HttpClient.instance.getJson(
              'https://live.douyin.com/123',
              header: headers,
            );
          case 'text':
            request = HttpClient.instance.getText(
              'https://live.douyin.com/123',
              header: headers,
            );
          default:
            request = HttpClient.instance.postJson(
              'https://live.douyin.com/123',
              header: headers,
            );
        }
        await expectLater(request, throwsA(isA<CoreError>()));
        expect(
          site.accountSession!.cookie.values['ttwid'],
          'rotated-device',
          reason: method,
        );
      }
    },
  );

  test('redirect response does not follow or widen cookie scope', () async {
    HttpClient.instance.dio = rejectingResponse(302);
    final response = await HttpClient.instance.head(
      'https://live.douyin.com/123',
      header: await site.getRequestHeaders(),
    );
    expect(response.statusCode, 302);
    expect(
      site.accountSession!.cookie.values['sessionid'],
      'synthetic-account',
    );
  });
}
