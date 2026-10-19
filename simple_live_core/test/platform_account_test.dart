import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:simple_live_core/simple_live_core.dart';
import 'package:simple_live_core/src/common/custom_interceptor.dart';
import 'package:simple_live_core/src/common/http_client.dart';
import 'package:test/test.dart';

LiveAccountSession session(
  LiveAccountPlatform platform,
  String cookie, {
  int version = 7,
}) => LiveAccountSession(
  platform: platform,
  cookie: PlatformCookie.parse(cookie),
  version: version,
);

Dio mockDio(FutureOr<Response<dynamic>> Function(RequestOptions) respond) {
  final dio = Dio();
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) async {
        try {
          handler.resolve(await respond(options));
        } on DioException catch (error) {
          handler.reject(error);
        }
      },
    ),
  );
  return dio;
}

LiveRoomDetail detail({dynamic data, int? version}) => LiveRoomDetail(
  roomId: '123',
  title: '',
  cover: '',
  userName: '',
  userAvatar: '',
  online: 0,
  status: true,
  url: '',
  data: data,
  accountSessionVersion: version,
);

void main() {
  group('Cookie import and scope', () {
    test(
      'retains complete header, equals, final cookie and duplicate last value',
      () {
        final cookie = PlatformCookie.parse(
          'Cookie: sessionid=synthetic=a=b; ttwid=device; sessionid=replacement==',
        );
        expect(cookie.values, {
          'sessionid': 'replacement==',
          'ttwid': 'device',
        });
        expect(cookie.toString(), isNot(contains('replacement')));
        expect(
          () => cookie.values['sessionid'] = 'changed',
          throwsUnsupportedError,
        );
      },
    );

    test(
      'bare ttwid migration does not prefix full headers or claim login',
      () async {
        final bare = PlatformCookie.parse(
          'synthetic-device',
          allowBareTtwid: true,
        );
        expect(bare.header, 'ttwid=synthetic-device');
        expect(bare.hasAccountSession, isFalse);
        expect(
          PlatformCookie.parse(
            'sessionid=synthetic; ttwid=device',
            allowBareTtwid: true,
          ).values['sessionid'],
          'synthetic',
        );
        final result = await PlatformAccountValidator.validate(
          LiveAccountSession(
            platform: LiveAccountPlatform.douyin,
            cookie: bare,
            version: 1,
          ),
        );
        expect(result.status, LiveAccountStatus.signedOut);
        expect(result.message, contains('仅保存了游客设备信息'));
      },
    );

    test('rejects malformed input and CRLF without reflecting credentials', () {
      for (final input in [
        'secret-no-equals',
        'sessionid=secret\r\nHost: evil.example',
      ]) {
        try {
          PlatformCookie.parse(input);
          fail('Expected invalid Cookie to be rejected');
        } on FormatException catch (error) {
          expect(error.toString(), isNot(contains('secret')));
        }
      }
    });

    test('Huya accepts legacy token or the complete modern token pair', () {
      for (final header in [
        'udb_l=synthetic-legacy',
        'udb_uid=synthetic-user; udb_biztoken=synthetic-token',
      ]) {
        final cookie = PlatformCookie.parse(header);
        expect(cookie.hasAccountSessionFor(LiveAccountPlatform.huya), isTrue);
        expect(cookie.hasAccountSession, isTrue);
        expect(cookie.hasAccountSessionFor(LiveAccountPlatform.douyu), isFalse);
      }
    });

    test('Huya identity, restore and incomplete cookies are not sessions', () {
      for (final header in [
        '',
        'udb_l=',
        'udb_uid=synthetic-user',
        'udb_biztoken=synthetic-token',
        'udb_uid=; udb_biztoken=synthetic-token',
        'udb_uid=synthetic-user; udb_biztoken=   ',
        'yyuid=12345',
        'udb_cred=synthetic-restore',
        'udb_uid=synthetic-user; udb_cred=synthetic-restore',
        'udb_anouid=synthetic-guest; udb_anobiztoken=synthetic-guest-token',
        'yyuid=12345; udb_status=1; udb_passdata=3; udb_login=1',
      ]) {
        final cookie = PlatformCookie.parse(header);
        expect(cookie.hasAccountSessionFor(LiveAccountPlatform.huya), isFalse);
        expect(cookie.hasAccountSession, isFalse);
      }
    });

    test('only explicit HTTPS account hosts receive platform Cookie', () {
      final account = session(LiveAccountPlatform.douyu, 'acf_auth=synthetic');
      expect(
        account.headersFor(
          Uri.parse('https://www.douyu.com/lapi/live/getH5Play/123'),
        )['cookie'],
        'acf_auth=synthetic',
      );
      for (final url in [
        'http://www.douyu.com/',
        'https://www.douyu.com.evil.example/',
        'https://cdn.douyu.com/',
        'https://live.douyin.com/',
        'https://www.douyu.com:8443/',
        'https://user@www.douyu.com/',
      ]) {
        expect(account.headersFor(Uri.parse(url)), isEmpty, reason: url);
      }
      expect(
        session(
          LiveAccountPlatform.huya,
          'udb_l=synthetic',
        ).headersFor(Uri.parse('http://wup.huya.com/')),
        isEmpty,
      );
    });

    test('response cookies cannot flatten unrelated or narrow scopes', () {
      final original = PlatformCookie.parse('sessionid=synthetic; ttwid=old');
      final merged = original
          .mergeResponseCookies(Uri.parse('https://live.douyin.com/123'), [
            'ttwid=new; Domain=.douyin.com; Path=/; Secure',
            'sessionid=evil; Domain=evil.example; Path=/',
            'sessionid=narrow; Domain=.douyin.com; Path=/private',
            'sessionid=hostonly; Path=/',
          ]);
      expect(merged.values, {'sessionid': 'synthetic', 'ttwid': 'new'});
      expect(original.values['ttwid'], 'old');
    });
  });

  group('validation states', () {
    test(
      'confirmed Bili identity, explicit expiry and transient failure stay distinct',
      () async {
        final account = session(
          LiveAccountPlatform.bilibili,
          'SESSDATA=synthetic',
        );
        var responseBody = <String, dynamic>{
          'code': 0,
          'data': {'mid': 42, 'uname': 'Test user', 'face': 'avatar'},
        };
        final dio = mockDio((options) {
          expect(
            options.uri.toString(),
            'https://api.bilibili.com/x/member/web/account',
          );
          expect(options.headers['cookie'], 'SESSDATA=synthetic');
          expect(options.followRedirects, isFalse);
          return Response(
            requestOptions: options,
            statusCode: 200,
            data: responseBody,
          );
        });
        final verified = await PlatformAccountValidator.validate(
          account,
          dio: dio,
        );
        expect(verified.status, LiveAccountStatus.verified);
        expect(verified.userId, '42');
        responseBody = {'code': -101};
        expect(
          (await PlatformAccountValidator.validate(account, dio: dio)).status,
          LiveAccountStatus.expired,
        );
        responseBody = {'code': -412};
        expect(
          (await PlatformAccountValidator.validate(account, dio: dio)).status,
          LiveAccountStatus.unavailable,
        );
        final unavailable = mockDio(
          (options) => throw DioException(
            requestOptions: options,
            type: DioExceptionType.connectionTimeout,
          ),
        );
        expect(
          (await PlatformAccountValidator.validate(
            account,
            dio: unavailable,
          )).status,
          LiveAccountStatus.unavailable,
        );
        expect(account.cookie.header, 'SESSDATA=synthetic');
        dio.close();
        unavailable.close();
      },
    );

    test(
      'public identity cookies do not qualify as an account session',
      () async {
        final dio = mockDio(
          (_) => throw StateError('No network identity endpoint authorized'),
        );
        for (final platform in LiveAccountPlatform.values) {
          final result = await PlatformAccountValidator.validate(
            session(platform, 'acf_uid=123; udb_uid=123; uid_tt=synthetic'),
            dio: dio,
          );
          expect(result.status, LiveAccountStatus.signedOut);
          expect(result.userId, isNull);
        }
        dio.close();
      },
    );
  });

  group('provider session integration', () {
    late Dio original;
    setUp(() {
      original = HttpClient.instance.dio;
    });
    tearDown(() {
      if (!identical(HttpClient.instance.dio, original)) {
        HttpClient.instance.dio.close();
      }
      HttpClient.instance.dio = original;
    });

    test(
      'Bili import/logout clears identity and device/signature caches',
      () async {
        final site = BiliBiliSite();
        site.userId = 123;
        site.buvid3 = 'old-device';
        BiliBiliSite.kImgKey = 'old-key';
        site.accountSession = session(
          LiveAccountPlatform.bilibili,
          'SESSDATA=synthetic; buvid3=final-device',
        );
        expect(site.userId, 0);
        expect(BiliBiliSite.kImgKey, isEmpty);
        expect(
          (await site.getHeader())['cookie'],
          contains('buvid3=final-device'),
        );
        site.accountSession = null;
        expect(site.cookie, isEmpty);
        expect(site.buvid3, isEmpty);
        expect(
          () => site.accountSession = session(
            LiveAccountPlatform.douyu,
            'acf_auth=synthetic',
          ),
          throwsArgumentError,
        );
      },
    );

    test(
      'Douyu uses account DID and preserves per-line actual downgrade/expiry',
      () async {
        final site = DouyuSite()
          ..accountSession = session(
            LiveAccountPlatform.douyu,
            'acf_auth=synthetic; acf_did=matched-device',
          );
        final seen = <RequestOptions>[];
        HttpClient.instance.dio = mockDio((options) {
          seen.add(options);
          expect(options.headers['cookie'], contains('acf_auth=synthetic'));
          expect(options.headers['cookie'], contains('acf_did=matched-device'));
          expect(options.followRedirects, isFalse);
          final downgraded = options.data.toString().contains('cdn=second');
          return Response(
            requestOptions: options,
            statusCode: 200,
            data: {
              'error': 0,
              'data': {
                'rate': downgraded ? 3 : 0,
                'rtmp_cdn': downgraded ? 'second-returned' : 'first-returned',
                'rtmp_url': 'https://cdn.example',
                'rtmp_live':
                    '${downgraded ? 'lower' : 'original'}.flv?token=synthetic&expire=${downgraded ? 300 : 0}',
                'multirates': [
                  {'rate': 0, 'name': '原画1080p60'},
                  {'rate': 3, 'name': '4M'},
                ],
              },
            },
          );
        });
        final result = await site.getPlayUrls(
          detail: detail(data: 'did=matched-device&sign=synthetic'),
          quality: LivePlayQuality(
            quality: '原画',
            data: DouyuPlayData(0, ['first', 'second']),
          ),
        );
        expect(seen, hasLength(2));
        expect(result.infoForUrl(result.urls.first).expiresInSeconds, 0);
        expect(result.infoForUrl(result.urls.last).expiresInSeconds, 300);
        expect(result.infoForUrl(result.urls.last).actualQuality, '4M');
        expect(result.infoForUrl(result.urls.last).actualRate, 3);
        expect(result.infoForUrl(result.urls.last).cdn, 'second-returned');
        expect(result.accountSessionVersion, 7);
        expect(result.headers, isNull); // Account Cookie is never a CDN header.
        expect(result.toString(), isNot(contains('synthetic')));
      },
    );

    test(
      'Douyu playback keeps captured session when account switches mid-request',
      () async {
        final site = DouyuSite()
          ..accountSession = session(
            LiveAccountPlatform.douyu,
            'acf_auth=old-synthetic; acf_did=old-device',
          );
        var requests = 0;
        HttpClient.instance.dio = mockDio((options) {
          requests++;
          if (requests == 1) {
            site.accountSession = session(
              LiveAccountPlatform.douyu,
              'acf_auth=new-synthetic; acf_did=new-device',
              version: 8,
            );
          }
          expect(options.headers['cookie'], contains('old-synthetic'));
          return Response(
            requestOptions: options,
            statusCode: 200,
            data: {
              'error': 0,
              'data': {
                'rate': 0,
                'expire': 0,
                'rtmp_url': 'https://cdn.example',
                'rtmp_live': '$requests.flv',
                'multirates': [],
              },
            },
          );
        });
        final result = await site.getPlayUrls(
          detail: detail(data: 'sign=synthetic'),
          quality: LivePlayQuality(
            quality: '原画',
            data: DouyuPlayData(0, ['a', 'b']),
          ),
        );
        expect(result.accountSessionVersion, 7);
        expect(site.accountSession?.version, 8);
      },
    );

    test(
      'Douyin complete Cookie goes to search, never foreign reflow host',
      () async {
        final site = DouyinSite()..cookie = 'sessionid=synthetic; ttwid=device';
        expect(
          (await site.getRequestHeaders())['cookie'],
          contains('sessionid=synthetic'),
        );
        expect(
          (await site.getRequestHeaders(
            uri: Uri.parse('https://webcast.amemv.com/'),
          ))['cookie'],
          isNull,
        );
        HttpClient.instance.dio = mockDio((options) {
          expect(options.uri.host, 'www.douyin.com');
          expect(options.headers['cookie'], contains('sessionid=synthetic'));
          return Response(
            requestOptions: options,
            statusCode: 200,
            data: {'data': [], 'has_more': 0},
          );
        });
        await site.searchRooms('fixture');
        site.accountSession = null;
        expect(
          (await site.getRequestHeaders())['cookie'],
          isNot(contains('sessionid=')),
        );
      },
    );

    test('Huya session only accompanies HTTPS room discovery', () async {
      final site = HuyaSite()
        ..accountSession = session(LiveAccountPlatform.huya, 'udb_l=synthetic');
      final room = {
        'roomInfo': {
          'eLiveStatus': 2,
          'tProfileInfo': {'sNick': 'test', 'sAvatar180': ''},
          'tLiveInfo': {
            'sIntroduction': '',
            'sRoomName': 'fixture',
            'sScreenshot': '',
            'lTotalCount': 1,
            'lProfileRoom': 123,
            'lYyid': 1,
            'tLiveStreamInfo': {
              'vStreamInfo': {'value': []},
              'vBitRateInfo': {'value': []},
            },
          },
        },
        'welcomeText': '',
        'roomProfile': {
          'liveLineUrl': base64Encode(utf8.encode('//cdn.example/fixture')),
        },
      };
      HttpClient.instance.dio = mockDio((options) {
        expect(options.uri.scheme, 'https');
        expect(options.uri.host, 'm.huya.com');
        expect(options.headers['cookie'], 'udb_l=synthetic');
        return Response(
          requestOptions: options,
          statusCode: 200,
          data: 'window.HNF_GLOBAL_INIT = ${jsonEncode(room)}</script>',
        );
      });
      expect(
        (await site.getRoomDetail(roomId: '123')).accountSessionVersion,
        7,
      );
      expect(
        HuyaSite.requestHeaders.keys.map((e) => e.toLowerCase()),
        isNot(contains('cookie')),
      );
    });
  });

  test(
    'logging and argument serialization never expose synthetic credentials',
    () async {
      final messages = <String>[];
      final oldSink = CoreLog.onPrintLog;
      final oldMode = CoreLog.requestLogType;
      CoreLog.onPrintLog = (_, message) => messages.add(message);
      CoreLog.requestLogType = RequestLogType.all;
      final dio = Dio()..interceptors.add(CustomInterceptor());
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            handler.resolve(
              Response(
                requestOptions: options,
                statusCode: 200,
                headers: Headers.fromMap({
                  'set-cookie': ['sessionid=response-secret'],
                }),
                data:
                    '<script>var unnamedCredential="response-secret"</script>',
              ),
            );
          },
        ),
      );
      try {
        await dio.get(
          'https://official.example/auth/path-secret?sign=query-secret',
          options: Options(headers: {'cookie': 'sessionid=header-secret'}),
        );
        CoreLog.error(StateError('cookie: raw-secret'));
        final output = messages.join('\n');
        for (final secret in [
          'path-secret',
          'query-secret',
          'header-secret',
          'response-secret',
          'raw-secret',
        ]) {
          expect(output, isNot(contains(secret)));
        }
        expect(
          DouyinDanmakuArgs(
            webRid: '1',
            roomId: '2',
            userId: '3',
            cookie: 'argument-secret',
          ).toString(),
          isNot(contains('argument-secret')),
        );
        expect(
          BiliBiliDanmakuArgs(
            roomId: 1,
            token: 'token-secret',
            serverHost: '',
            buvid: '',
            uid: 1,
            cookie: 'argument-secret',
          ).toString(),
          isNot(contains('-secret')),
        );
      } finally {
        CoreLog.onPrintLog = oldSink;
        CoreLog.requestLogType = oldMode;
        dio.close();
      }
    },
  );
}
