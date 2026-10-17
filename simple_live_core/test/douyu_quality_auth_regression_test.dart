import 'dart:async';

import 'package:dio/dio.dart';
import 'package:simple_live_core/simple_live_core.dart';
import 'package:simple_live_core/src/common/http_client.dart';
import 'package:test/test.dart';

const _cookie =
    'acf_auth=valid-fixture; dy_auth=conflicting-fixture; '
    'acf_jwt_token=retained-fixture; dy_did=same-device';

LiveAccountSession _session(String cookie, {int version = 1}) =>
    LiveAccountSession(
      platform: LiveAccountPlatform.douyu,
      cookie: PlatformCookie.parse(cookie),
      version: version,
    );

LiveRoomDetail _detail() => LiveRoomDetail(
  roomId: '123',
  title: '',
  cover: '',
  userName: '',
  userAvatar: '',
  online: 0,
  status: true,
  url: '',
  data: 'did=same-device&sign=fixture',
);

Map<String, dynamic> _response(int? rate) => {
  'error': 0,
  'data': {
    'rate': rate,
    'rtmp_cdn': 'hw-h5',
    'rtmp_url': 'https://fixture.invalid',
    'rtmp_live': 'rate-$rate.flv?expire=${rate == 0 ? 0 : 300}',
    'multirates': [
      {'rate': 0, 'name': '原画1080P60'},
      {'rate': 4, 'name': '蓝光4M'},
    ],
  },
};

Future<LivePlayUrl> _play(DouyuSite site) => site.getPlayUrls(
  detail: _detail(),
  quality: LivePlayQuality(
    quality: '原画1080P60',
    data: DouyuPlayData(0, ['hw-h5']),
  ),
);

class _FreshDouyu extends DouyuSite {
  List<LivePlayQuality> qualities = [
    LivePlayQuality(quality: '蓝光4M', data: DouyuPlayData(4, ['lower-cdn'])),
    LivePlayQuality(
      quality: '原画1080P60',
      data: DouyuPlayData(0, ['fresh-cdn']),
    ),
  ];
  LivePlayQuality? requestedQuality;

  @override
  Future<LiveRoomDetail> getRoomDetail({required String roomId}) async =>
      _detail();

  @override
  Future<List<LivePlayQuality>> getPlayQualites({
    required LiveRoomDetail detail,
  }) async => qualities;

  @override
  Future<LivePlayUrl> getPlayUrls({
    required LiveRoomDetail detail,
    required LivePlayQuality quality,
  }) async {
    requestedQuality = quality;
    return LivePlayUrl(urls: ['https://fixture.invalid/fresh.flv']);
  }
}

void main() {
  late Dio original;
  setUp(() => original = HttpClient.instance.dio);
  tearDown(() {
    if (!identical(HttpClient.instance.dio, original)) {
      HttpClient.instance.dio.close();
    }
    HttpClient.instance.dio = original;
  });

  void respond(FutureOr<Map<String, dynamic>> Function(RequestOptions) reply) {
    HttpClient.instance.dio = Dio()
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (request, handler) async {
            handler.resolve(
              Response(
                requestOptions: request,
                statusCode: 200,
                data: await reply(request),
              ),
            );
          },
        ),
      );
  }

  test(
    'conflicting login retries once and recovers authenticated original quality',
    () async {
      final site = DouyuSite()..accountSession = _session(_cookie);
      final requests = <RequestOptions>[];
      respond((request) {
        requests.add(request);
        final cookie = PlatformCookie.parse(
          request.headers['cookie'] as String,
        );
        expect(
          request.uri.toString(),
          'https://www.douyu.com/lapi/live/getH5Play/123',
        );
        expect(request.followRedirects, isFalse);
        expect(cookie.values['acf_auth'], 'valid-fixture');
        expect(cookie.values['acf_jwt_token'], 'retained-fixture');
        expect(cookie.values['acf_did'], 'same-device');
        expect(cookie.values['dy_did'], 'same-device');
        return _response(cookie.values.containsKey('dy_auth') ? 4 : 0);
      });
      final result = await _play(site);
      expect(requests, hasLength(2));
      expect(requests.first.data, requests.last.data);
      expect(result.actualRate, 0);
      expect(result.actualQuality, '原画1080P60');
      expect(result.expiresInSeconds, 0);
      expect(result.infoForUrl(result.urls.single).actualRate, 0);
      expect(result.headers, isNull);
      expect(site.accountSession!.cookie.header, _cookie);
      expect(site.accountSession!.version, 1);
    },
  );

  for (final fixture in [
    (name: 'already original', cookie: _cookie, rate: 0),
    (name: 'unknown rate', cookie: _cookie, rate: null),
    (name: 'no legacy credential', cookie: 'dy_auth=fixture', rate: 4),
    (name: 'no conflicting credential', cookie: 'acf_auth=fixture', rate: 4),
    (name: 'guest', cookie: '', rate: 4),
  ]) {
    test('${fixture.name} does not trigger an auth retry', () async {
      var requests = 0;
      respond((_) {
        requests++;
        return _response(fixture.rate);
      });
      final result = await _play(
        DouyuSite()..accountSession = _session(fixture.cookie),
      );
      expect(requests, 1);
      expect(result.actualRate, fixture.rate);
    });
  }

  for (final failure in ['downgrade', 'api error', 'invalid URL', 'timeout']) {
    test(
      'compatibility $failure retains original usable response and metadata',
      () async {
        var requests = 0;
        respond((_) async {
          requests++;
          if (requests == 1) return _response(4);
          if (failure == 'timeout') {
            await Future<void>.delayed(const Duration(milliseconds: 2100));
          }
          if (failure == 'api error') return {'error': -5};
          final response = _response(failure == 'downgrade' ? 4 : 0);
          if (failure == 'invalid URL') {
            (response['data'] as Map)['rtmp_url'] = 'file://private';
          }
          return response;
        });
        final result = await _play(
          DouyuSite()..accountSession = _session(_cookie),
        );
        expect(requests, 2);
        expect(result.actualRate, 4);
        expect(result.actualQuality, '蓝光4M');
        expect(result.expiresInSeconds, 300);
        expect(
          result.urls.single,
          'https://fixture.invalid/rate-4.flv?expire=300',
        );
      },
    );
  }

  test(
    'account switch during compatibility retry preserves request snapshot',
    () async {
      final site = DouyuSite()..accountSession = _session(_cookie);
      var requests = 0;
      respond((request) {
        requests++;
        final cookie = PlatformCookie.parse(
          request.headers['cookie'] as String,
        );
        expect(cookie.values['acf_auth'], 'valid-fixture');
        expect(cookie.values['acf_did'], 'same-device');
        if (requests == 1) {
          site.accountSession = _session(
            'acf_auth=new-fixture; dy_did=new-device',
            version: 2,
          );
          return _response(4);
        }
        return _response(0);
      });
      final result = await _play(site);
      expect(result.accountSessionVersion, 1);
      expect(site.accountSession!.version, 2);
      expect(site.accountSession!.cookie.values['acf_auth'], 'new-fixture');
    },
  );

  test(
    'renamed Douyu original quality recovers by rate with fresh CDN data',
    () async {
      final site = _FreshDouyu();
      final selected = LivePlayQuality(
        quality: '原画',
        data: DouyuPlayData(0, ['old-cdn']),
      );
      final result = await PlaybackSource.refresh(site, '123', selected);
      expect(result!.qualityIndex, 1);
      expect(site.requestedQuality, same(site.qualities[1]));
      expect((site.requestedQuality!.data as DouyuPlayData).cdns, [
        'fresh-cdn',
      ]);
      expect(result.urls.urls.single, 'https://fixture.invalid/fresh.flv');
      expect((selected.data as DouyuPlayData).cdns, ['old-cdn']);
    },
  );

  test(
    'matching name cannot silently substitute a missing Douyu rate',
    () async {
      final site = _FreshDouyu()
        ..qualities = [
          LivePlayQuality(quality: '原画', data: DouyuPlayData(4, ['lower-cdn'])),
        ];
      final selected = LivePlayQuality(
        quality: '原画',
        data: DouyuPlayData(0, ['old-cdn']),
      );
      await expectLater(
        PlaybackSource.refresh(site, '123', selected),
        throwsStateError,
      );
      expect(site.requestedQuality, isNull);
      final result = await PlaybackSource.refresh(
        site,
        '123',
        selected,
        allowQualityFallback: true,
      );
      expect(result!.qualityIndex, 0);
      expect((site.requestedQuality!.data as DouyuPlayData).rate, 4);
    },
  );
}
