import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:simple_live_core/simple_live_core.dart';
import 'package:simple_live_core/src/common/http_client.dart';
import 'package:test/test.dart';

LiveRoomDetail room({bool live = true, dynamic data}) => LiveRoomDetail(
  roomId: '123',
  title: 'fixture',
  cover: '',
  userName: 'fixture',
  userAvatar: '',
  online: 0,
  status: live,
  url: '',
  data: data,
);

class RefreshedDouyin extends DouyinSite {
  bool live = true;
  @override
  Future<LiveRoomDetail> getRoomDetail({required String roomId}) async => room(
    live: live,
    data: {
      'live_core_sdk_data': {
        'pull_data': {
          'options': {
            'qualities': [
              {'name': '原画', 'level': 4, 'sdk_key': 'origin'},
            ],
          },
          'stream_data': jsonEncode({
            'data': {
              'origin': {
                'main': {
                  'flv': 'https://fixture.invalid/new.flv',
                  'hls': 'https://fixture.invalid/new.m3u8',
                },
              },
            },
          }),
        },
      },
    },
  );
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

  void respond(dynamic Function(RequestOptions) callback) {
    HttpClient.instance.dio = Dio()
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (request, handler) => handler.resolve(
            Response(
              requestOptions: request,
              statusCode: 200,
              data: callback(request),
            ),
          ),
        ),
      );
  }

  test(
    'Douyin recovery replaces embedded URLs in the old quality object',
    () async {
      final selected = LivePlayQuality(
        quality: '原画',
        data: ['https://fixture.invalid/expired.flv'],
      );
      final refreshed = await PlaybackSource.refresh(
        RefreshedDouyin(),
        '123',
        selected,
      );
      expect(refreshed!.urls.urls, [
        'https://fixture.invalid/new.flv',
        'https://fixture.invalid/new.m3u8',
      ]);
      expect(selected.data, ['https://fixture.invalid/expired.flv']);
      expect(
        await PlaybackSource.refresh(
          RefreshedDouyin()..live = false,
          '123',
          selected,
        ),
        isNull,
      );
    },
  );

  test('Douyu retains successful CDNs when another CDN fails', () async {
    final requested = <String>[];
    respond((request) {
      final cdn = Uri.splitQueryString(request.data as String)['cdn']!;
      requested.add(cdn);
      if (cdn == 'broken') return {'error': -1};
      return {
        'error': 0,
        'data': {
          'rtmp_url': 'https://$cdn.invalid',
          'rtmp_live': 'live.flv',
          'cdn': cdn,
          'rate': 0,
          'expire': 0,
          'multirates': [
            {'rate': 0, 'name': '原画'},
          ],
        },
      };
    });
    final urls = await DouyuSite().getPlayUrls(
      detail: room(data: 'fixture=1'),
      quality: LivePlayQuality(
        quality: '原画',
        data: DouyuPlayData(0, ['a', 'broken', 'c']),
      ),
    );
    expect(requested, containsAll(['a', 'broken', 'c']));
    expect(urls.urls, [
      'https://a.invalid/live.flv',
      'https://c.invalid/live.flv',
    ]);
  });

  test(
    'Douyu accepts JSON text and numeric strings without losing quality',
    () async {
      respond(
        (_) => jsonEncode({
          'error': '0',
          'data': {
            'cdnsWithName': [
              null,
              {'cdn': 'scdn'},
              {'cdn': 'tct'},
            ],
            'multirates': [
              null,
              {'name': '原画', 'rate': '0'},
              {'name': 'invalid'},
            ],
          },
        }),
      );
      final qualities = await DouyuSite().getPlayQualites(
        detail: room(data: 'fixture=1'),
      );
      expect(qualities.single.quality, '原画');
      final data = qualities.single.data as DouyuPlayData;
      expect(data.rate, 0);
      expect(data.cdns, ['tct', 'scdn']);
    },
  );

  for (final response in <Object?>[
    '<html>synthetic-credential-do-not-log</html>',
    {'error': -1, 'data': 'synthetic-credential-do-not-log'},
    {'error': 0, 'data': ''},
    {
      'error': 0,
      'data': {'cdnsWithName': [], 'multirates': []},
    },
    {
      'error': 0,
      'data': {'cdnsWithName': 'invalid', 'multirates': []},
    },
    [],
    null,
  ]) {
    test(
      'Douyu rejects malformed quality response ${response.runtimeType} safely',
      () async {
        respond((_) => response);
        await expectLater(
          DouyuSite().getPlayQualites(detail: room(data: 'fixture=1')),
          throwsA(
            isA<StateError>().having(
              (e) => e.toString(),
              'safe error',
              allOf(contains('斗鱼'), isNot(contains('synthetic-credential'))),
            ),
          ),
        );
      },
    );
  }

  test(
    'Douyu source response supports JSON text and rejects non-HTTP URLs',
    () async {
      respond((request) {
        final cdn = Uri.splitQueryString(request.data as String)['cdn'];
        return jsonEncode({
          'error': 0,
          'data': {
            'rtmp_url': cdn == 'invalid'
                ? 'file:///private'
                : 'https://cdn.invalid',
            'rtmp_live': 'live.flv',
            'rate': 0,
            'multirates': 'unexpected',
          },
        });
      });
      final urls = await DouyuSite().getPlayUrls(
        detail: room(data: 'fixture=1'),
        quality: LivePlayQuality(
          quality: '原画',
          data: DouyuPlayData(0, ['invalid', 'valid']),
        ),
      );
      expect(urls.urls, ['https://cdn.invalid/live.flv']);
    },
  );

  test(
    'Douyu reports total failure without returning malformed URLs',
    () async {
      respond((_) => {'error': -1});
      await expectLater(
        DouyuSite().getPlayUrls(
          detail: room(data: 'fixture=1'),
          quality: LivePlayQuality(
            quality: '原画',
            data: DouyuPlayData(0, ['a', 'b']),
          ),
        ),
        throwsStateError,
      );
    },
  );

  test('line identity survives reorder and signed URL changes', () {
    final old = LivePlayUrl(
      urls: [
        'https://a.invalid/live.flv?old=1',
        'https://b.invalid/live.flv?old=1',
      ],
    );
    final fresh = LivePlayUrl(urls: ['https://b.invalid/live.flv?new=2']);
    expect(fresh.indexForIdentity(old.identityForUrl(old.urls[1])), 0);
    expect(
      PlaybackSource.qualityIndexFor([
        LivePlayQuality(quality: '高清', data: null),
        LivePlayQuality(quality: '原画', data: null),
      ], '原画'),
      1,
    );
  });

  test(
    'quality-first recovery does not silently substitute a missing quality',
    () async {
      final selected = LivePlayQuality(quality: '已移除的画质', data: []);
      await expectLater(
        PlaybackSource.refresh(RefreshedDouyin(), '123', selected),
        throwsStateError,
      );
      final fallback = await PlaybackSource.refresh(
        RefreshedDouyin(),
        '123',
        selected,
        allowQualityFallback: true,
      );
      expect(fallback!.qualities[fallback.qualityIndex].quality, '原画');
    },
  );

  test(
    'Douyin user search includes offline anchors with stable profile IDs',
    () async {
      respond((request) {
        expect(request.uri.path, '/aweme/v1/web/discover/search/');
        expect(request.uri.queryParameters['search_channel'], 'aweme_user_web');
        expect(request.uri.queryParameters['offset'], '10');
        expect(request.uri.queryParameters['a_bogus'], isNotEmpty);
        expect(request.headers['cookie'], contains('sessionid=synthetic'));
        return {
          'status_code': 0,
          'has_more': 1,
          'user_list': [
            {
              'user_info': {
                'nickname': '直播主播',
                'web_rid': '123',
                'live_status': 1,
              },
            },
            {
              'user_info': {
                'nickname': '离线主播',
                'sec_uid': 'stable-id',
                'room_id': 0,
                'live_status': 0,
                'avatar_thumb': {
                  'url_list': ['https://fixture.invalid/avatar'],
                },
              },
            },
            {
              'user_info': {'nickname': '无效数据', 'room_id': 0},
            },
          ],
        };
      });
      final results =
          await (DouyinSite()..cookie = 'sessionid=synthetic; ttwid=device')
              .searchAnchors('fixture', page: 2);
      expect(results.items.map((item) => item.roomId), [
        '123',
        'user:stable-id',
      ]);
      expect(results.items.last.liveStatus, isFalse);
      expect(results.hasMore, isTrue);
    },
  );

  test(
    'Douyin restriction is actionable rather than an empty search result',
    () async {
      respond((_) => {'status_code': 0, 'verify_data': {}, 'user_list': []});
      await expectLater(
        DouyinSite().searchAnchors('fixture'),
        throwsA(predicate((error) => error.toString().contains('登录或完成验证'))),
      );
    },
  );

  test(
    'offline Douyin profile can be followed without a transient room ID',
    () async {
      respond((request) {
        expect(request.uri.path, '/aweme/v1/web/user/profile/other/');
        expect(request.uri.queryParameters['sec_user_id'], 'stable-id');
        return {
          'status_code': 0,
          'user': {'nickname': '离线主播', 'live_status': 0, 'room_id': 0},
        };
      });
      final detail = await DouyinSite().getRoomDetail(roomId: 'user:stable-id');
      expect(detail.roomId, 'user:stable-id');
      expect(detail.status, isFalse);
      expect(detail.userName, '离线主播');
    },
  );

  test(
    'late same-revision response cannot remove a renewed login token',
    () async {
      final site = BiliBiliSite()
        ..accountSession = LiveAccountSession(
          platform: LiveAccountPlatform.bilibili,
          version: 1,
          cookie: PlatformCookie.parse('SESSDATA=old; buvid3=device'),
        );
      final old = await site.getHeader() as AccountRequestHeaders;
      final newer = await site.getHeader() as AccountRequestHeaders;
      final uri = Uri.parse('https://www.bilibili.com/');
      newer.acceptResponseCookies(uri, [
        'SESSDATA=new; Domain=.bilibili.com; Path=/',
      ]);
      old.acceptResponseCookies(uri, [
        'SESSDATA=; Domain=.bilibili.com; Path=/; Max-Age=0',
        'independent=value; Domain=.bilibili.com; Path=/',
      ]);
      expect(site.accountSession!.cookie.values['SESSDATA'], 'new');
      expect(site.accountSession!.cookie.values['independent'], 'value');
    },
  );
}
