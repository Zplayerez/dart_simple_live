import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:simple_live_core/simple_live_core.dart';
import 'package:test/test.dart';

const fixtures = {
  LiveAccountPlatform.douyu: (
    cookie: 'acf_auth=synthetic-private; dy_did=synthetic-device',
    host: 'passport.douyu.com',
    path: '/wgapi/member/passport/safeAuth',
    success: {'error': 0, 'data': <String, dynamic>{}},
    expired: {'error': 16, 'data': <String, dynamic>{}},
    rejected: {'error': 99, 'data': <String, dynamic>{}},
  ),
  LiveAccountPlatform.huya: (
    cookie: 'udb_uid=123; udb_biztoken=synthetic-private',
    host: 'l.huya.com',
    path: '/udb_web/udbport2.php',
    success: {
      'isLogined': true,
      'uid': 123,
      'userNick': 'Test user',
      'userLogo': 'https://example.test/avatar.png',
    },
    expired: {'isLogined': false, 'uid': 0},
    rejected: {'isLogined': true, 'uid': 0},
  ),
  LiveAccountPlatform.douyin: (
    cookie: 'sessionid=synthetic-private; ttwid=synthetic-device',
    host: 'live.douyin.com',
    path: '/webcast/user/me/',
    success: {
      'status_code': 0,
      'data': {
        'id_str': '123',
        'nickname': 'Test user',
        'avatar_thumb': {
          'url_list': ['https://example.test/avatar.png'],
        },
      },
    },
    expired: {'status_code': 20003, 'data': <String, dynamic>{}},
    rejected: {
      'status_code': 0,
      'data': {'id_str': '0'},
    },
  ),
};

void main() {
  for (final entry in fixtures.entries) {
    group('${entry.key.name} server validation', () {
      late Dio dio;
      late LiveAccountSession session;
      late List<RequestOptions> requests;
      dynamic responseBody;
      var statusCode = 200;
      var timeout = false;

      setUp(() {
        requests = [];
        responseBody = entry.value.success;
        statusCode = 200;
        timeout = false;
        session = LiveAccountSession(
          platform: entry.key,
          cookie: PlatformCookie.parse(entry.value.cookie),
          version: 1,
        );
        dio = Dio()
          ..interceptors.add(
            InterceptorsWrapper(
              onRequest: (request, handler) {
                requests.add(request);
                if (timeout) {
                  handler.reject(
                    DioException(
                      requestOptions: request,
                      type: DioExceptionType.receiveTimeout,
                      message: 'synthetic-private',
                    ),
                  );
                } else {
                  handler.resolve(
                    Response(
                      requestOptions: request,
                      statusCode: statusCode,
                      data: responseBody,
                      headers: Headers.fromMap({
                        if (statusCode == 302)
                          'location': ['https://untrusted.example/login'],
                      }),
                    ),
                  );
                }
              },
            ),
          );
      });
      tearDown(() => dio.close());

      Future<LiveAccountValidation> validate() =>
          PlatformAccountValidator.validate(session, dio: dio);

      test(
        'requests the official self/session endpoint without redirects',
        () async {
          final result = await validate();
          expect(result.status, LiveAccountStatus.verified);
          expect(requests, hasLength(1));
          final request = requests.single;
          expect(request.uri.scheme, 'https');
          expect(request.uri.host, entry.value.host);
          expect(request.uri.path, entry.value.path);
          expect(request.headers['cookie'], entry.value.cookie);
          expect(request.followRedirects, isFalse);
          expect(request.validateStatus(302), isFalse);
          expect(request.validateStatus(503), isFalse);
          expect(result.playbackCapability, isNull);
          // Authentication is not a claim that a particular room granted 1080p60.
          if (entry.key != LiveAccountPlatform.douyu) {
            expect(result.userId, '123');
            expect(result.displayName, 'Test user');
            expect(result.avatarUrl, 'https://example.test/avatar.png');
          } else {
            expect(request.uri.queryParameters['did'], 'synthetic-device');
            expect(request.uri.queryParameters['client_id'], '1');
            expect(
              request.uri.queryParameters['redirect_url'],
              'https://www.douyu.com/',
            );
          }
        },
      );

      test('JSON text from a valid self response is accepted', () async {
        responseBody = jsonEncode(entry.value.success);
        expect((await validate()).status, LiveAccountStatus.verified);
      });

      test(
        'explicit server logout instructs re-login and retains credential',
        () async {
          responseBody = entry.value.expired;
          final result = await validate();
          expect(result.status, LiveAccountStatus.expired);
          expect(result.message, contains('重新网页登录'));
          expect(result.userId, isNull);
          expect(session.cookie.header, entry.value.cookie);
        },
      );

      test(
        'unknown error or missing identity is a temporary verification failure',
        () async {
          responseBody = entry.value.rejected;
          final result = await validate();
          expect(result.status, LiveAccountStatus.unavailable);
          expect(result.userId, isNull);
        },
      );

      test(
        'malformed response is never mistaken for authentication or expiry',
        () async {
          for (final body in [
            '',
            '<html>captcha</html>',
            [],
            {},
            {'data': {}},
          ]) {
            responseBody = body;
            expect((await validate()).status, LiveAccountStatus.unavailable);
          }
        },
      );

      test(
        'HTTP errors and redirects cannot authenticate from response fields',
        () async {
          for (final code in [301, 302, 401, 403, 429, 503]) {
            statusCode = code;
            expect((await validate()).status, LiveAccountStatus.unavailable);
          }
          expect(requests, hasLength(6));
          expect(requests.every((r) => r.uri.host == entry.value.host), isTrue);
        },
      );

      test(
        'transport failures keep credentials and redact exceptions',
        () async {
          timeout = true;
          final result = await validate();
          expect(result.status, LiveAccountStatus.unavailable);
          expect(result.message, isNot(contains('synthetic-private')));
          expect(result.message, contains('重新验证'));
          expect(session.cookie.header, entry.value.cookie);
        },
      );
    });
  }

  test(
    'new authentication hosts are restricted to their exact check endpoint',
    () {
      final douyu = LiveAccountSession(
        platform: LiveAccountPlatform.douyu,
        cookie: PlatformCookie.parse('acf_auth=synthetic'),
        version: 1,
      );
      final huya = LiveAccountSession(
        platform: LiveAccountPlatform.huya,
        cookie: PlatformCookie.parse('udb_l=synthetic'),
        version: 1,
      );
      for (final value in [
        'https://passport.douyu.com/',
        'https://passport.douyu.com/wgapi/member/passport/logout',
        'https://passport.douyu.com.evil.test/wgapi/member/passport/safeAuth',
        'http://passport.douyu.com/wgapi/member/passport/safeAuth',
        'https://passport.douyu.com:8443/wgapi/member/passport/safeAuth',
        'https://user@passport.douyu.com/wgapi/member/passport/safeAuth',
        'https://l.huya.com/udb_web/udbport2.php?m=HuyaLogin&do=checkLogin',
      ]) {
        expect(douyu.headersFor(Uri.parse(value)), isEmpty, reason: value);
      }
      for (final value in [
        'https://l.huya.com/',
        'https://l.huya.com/udb_web/udbport2.php?m=HuyaLogin&do=huyaLogout',
        'https://l.huya.com/udb_web/udbport2.php?m=HuyaOutside&do=checkLogin',
        'http://l.huya.com/udb_web/udbport2.php?m=HuyaLogin&do=checkLogin',
        'https://passport.douyu.com/wgapi/member/passport/safeAuth',
      ]) {
        expect(huya.headersFor(Uri.parse(value)), isEmpty, reason: value);
      }
    },
  );
}
