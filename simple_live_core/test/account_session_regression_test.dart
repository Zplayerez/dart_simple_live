import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:simple_live_core/simple_live_core.dart';
import 'package:simple_live_core/src/common/http_client.dart';
import 'package:simple_live_core/src/scripts/douyu_sign.dart';
import 'package:test/test.dart';

void main() {
  late Dio original;
  setUp(() {
    original = HttpClient.instance.dio;
  });
  tearDown(() {
    if (!identical(original, HttpClient.instance.dio)) {
      HttpClient.instance.dio.close();
    }
    HttpClient.instance.dio = original;
  });

  test('Douyu DID is passed into real JS runtime as data', () {
    const device = 'synthetic\'"\\device\n';
    final output = DouyuSign.getSign(
      'function ub98484234(rid,did,time) { return JSON.stringify({rid:rid,did:did}); }',
      '123',
      deviceId: device,
    );
    expect(jsonDecode(output), {'rid': '123', 'did': device});
  });

  test(
    'accepted server Cookie rotation reaches callback and merges concurrent responses',
    () async {
      final site = BiliBiliSite()
        ..accountSession = LiveAccountSession(
          platform: LiveAccountPlatform.bilibili,
          cookie: PlatformCookie.parse('SESSDATA=synthetic; buvid3=device'),
          version: 1,
        );
      final updates = <LiveAccountSession>[];
      site.onAccountSessionUpdated = updates.add;
      final earlier = await site.getHeader() as AccountRequestHeaders;
      final later = await site.getHeader() as AccountRequestHeaders;
      final uri = Uri.parse(
        'https://api.live.bilibili.com/room/v1/Area/getList',
      );
      earlier.acceptResponseCookies(uri, [
        'new_a=a; Domain=.bilibili.com; Path=/; Secure',
      ]);
      later.acceptResponseCookies(uri, [
        'new_b=b; Domain=.bilibili.com; Path=/; Secure',
      ]);
      expect(site.accountSession!.cookie.values, containsPair('new_a', 'a'));
      expect(site.accountSession!.cookie.values, containsPair('new_b', 'b'));
      expect(updates.map((e) => e.version), [1, 1]);
      final dio = Dio();
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            handler.resolve(
              Response(
                requestOptions: options,
                statusCode: 200,
                headers: Headers.fromMap({
                  'set-cookie': [
                    'SESSDATA=rotated-synthetic; Domain=.bilibili.com; Path=/; Secure',
                  ],
                }),
                data: {'code': 0, 'data': []},
              ),
            );
          },
        ),
      );
      HttpClient.instance.dio = dio;
      await site.getCategores();
      expect(updates.last.cookie.values['SESSDATA'], 'rotated-synthetic');
      site.accountSession = null;
      earlier.acceptResponseCookies(uri, [
        'SESSDATA=stale-synthetic; Domain=.bilibili.com; Path=/',
      ]);
      expect(site.accountSession, isNull);
      expect(updates, hasLength(3));
    },
  );

  test(
    'expired server Cookie clears only named value and respects Max-Age precedence',
    () {
      final cookie = PlatformCookie.parse('sessionid=synthetic; ttwid=device');
      final uri = Uri.parse('https://live.douyin.com/123');
      final expired = cookie.mergeResponseCookies(uri, [
        'sessionid=; Domain=.douyin.com; Path=/; Expires=Thu, 01 Jan 1970 00:00:00 GMT',
      ]);
      expect(expired.values, {'ttwid': 'device'});
      final renewed = cookie.mergeResponseCookies(uri, [
        'sessionid=renewed; Domain=.douyin.com; Path=/; Max-Age=60; Expires=Thu, 01 Jan 1970 00:00:00 GMT',
      ]);
      expect(renewed.values['sessionid'], 'renewed');
    },
  );

  test('Douyin HTML fallback keeps login Cookie for page and danmaku', () async {
    final site = DouyinSite()
      ..cookie = 'sessionid=synthetic; ttwid=original-device';
    final received = <RequestOptions>[];
    final room = {
      'id_str': '999',
      'status': 2,
      'title': 'fixture',
      'owner': {
        'nickname': 'fixture',
        'avatar_thumb': {
          'url_list': [''],
        },
        'signature': '',
      },
      'cover': {
        'url_list': [''],
      },
      'room_view_stats': {'display_value': 1},
      'stream_url': {},
    };
    final state = {
      'state': {
        'appStore': {},
        'userStore': {
          'odin': {'user_unique_id': '888'},
        },
        'roomStore': {
          'roomInfo': {'room': room, 'anchor': {}},
        },
      },
    };
    final html = jsonEncode(state).replaceAll('"', r'\"') + r']\n';
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          received.add(options);
          expect(
            options.headers['cookie'] ?? options.headers['Cookie'],
            contains('sessionid=synthetic'),
          );
          if (options.method == 'HEAD') {
            handler.resolve(
              Response(
                requestOptions: options,
                statusCode: 200,
                data: '',
                headers: Headers.fromMap({
                  'set-cookie': [
                    'ttwid=new-device; Domain=.douyin.com; Path=/; Secure',
                  ],
                }),
              ),
            );
          } else if (options.uri.path.contains('/webcast/')) {
            // Explicitly force the HTML fallback without any live endpoint call.
            handler.resolve(
              Response(
                requestOptions: options,
                statusCode: 200,
                data: {'data': []},
              ),
            );
          } else {
            handler.resolve(
              Response(requestOptions: options, statusCode: 200, data: html),
            );
          }
        },
      ),
    );
    HttpClient.instance.dio = dio;
    final previousLogState = CoreLog.enableLog;
    CoreLog.enableLog = false;
    try {
      final result = await site.getRoomDetailByWebRid('123');
      expect(received.any((r) => r.method == 'HEAD'), isTrue);
      final args = result.danmakuData as DouyinDanmakuArgs;
      expect(args.cookie, contains('sessionid=synthetic'));
      expect(args.cookie, contains('ttwid=new-device'));
      expect(site.accountSession!.cookie.values['ttwid'], 'new-device');
    } finally {
      CoreLog.enableLog = previousLogState;
    }
  });

  test(
    'untrusted danmaku destinations reject before any credential transmission',
    () async {
      final bili = BiliBiliDanmaku();
      await expectLater(
        bili.start(
          BiliBiliDanmakuArgs(
            roomId: 1,
            token: 'synthetic',
            serverHost: 'broadcastlv.chat.bilibili.com.evil.example',
            buvid: '',
            uid: 0,
            cookie: 'SESSDATA=synthetic',
          ),
        ),
        throwsStateError,
      );
      final douyin = DouyinDanmaku()..serverUrl = 'wss://evil.example/';
      await expectLater(
        douyin.start(
          DouyinDanmakuArgs(
            webRid: '1',
            roomId: '2',
            userId: '3',
            cookie: 'sessionid=synthetic',
          ),
        ),
        throwsStateError,
      );
    },
  );
  test('official WSS endpoints allow default or explicit 443 only', () {
    for (final endpoint in [
      'wss://broadcastlv.chat.bilibili.com/sub',
      'wss://broadcastlv.chat.bilibili.com:443/sub',
    ]) {
      expect(
        LiveAccountSession.permitsDanmakuEndpoint(
          LiveAccountPlatform.bilibili,
          Uri.parse(endpoint),
        ),
        isTrue,
      );
    }
    expect(
      LiveAccountSession.permitsDanmakuEndpoint(
        LiveAccountPlatform.douyin,
        Uri.parse('wss://webcast3-ws-web-lq.douyin.com/webcast/im/push/v2/'),
      ),
      isTrue,
    );
    expect(
      LiveAccountSession.permitsDanmakuEndpoint(
        LiveAccountPlatform.bilibili,
        Uri.parse('wss://broadcastlv.chat.bilibili.com:8443/sub'),
      ),
      isFalse,
    );
  });
}
