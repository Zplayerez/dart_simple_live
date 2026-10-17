import 'package:dio/dio.dart';
import 'package:simple_live_core/simple_live_core.dart';
import 'package:simple_live_core/src/common/http_client.dart';
import 'package:test/test.dart';

class _FreshDouyu extends DouyuSite {
  @override
  Future<LiveRoomDetail> getRoomDetail({required String roomId}) async =>
      LiveRoomDetail(
        roomId: roomId,
        title: '',
        cover: '',
        userName: '',
        userAvatar: '',
        online: 0,
        status: true,
        url: '',
        data: 'sign=fresh-fixture',
      );
}

void main() {
  late Dio original;
  setUp(() => original = HttpClient.instance.dio);
  tearDown(() {
    HttpClient.instance.dio.close();
    HttpClient.instance.dio = original;
  });

  for (final code in [-5, -3]) {
    test('Douyu discovery $code only uses known CDN fallback for -5', () async {
      final requests = <Map<String, String>>[];
      HttpClient.instance.dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (request, handler) {
              final args = Uri.splitQueryString(request.data as String);
              requests.add(args);
              expect(args['sign'], 'fresh-fixture');
              handler.resolve(
                Response(
                  requestOptions: request,
                  statusCode: 200,
                  data: args['rate'] == '-1'
                      ? {'error': code, 'data': null}
                      : {
                          'error': 0,
                          'data': {
                            'rate': 0,
                            'rtmp_cdn': args['cdn'],
                            'rtmp_url': 'https://fixture.invalid',
                            'rtmp_live': 'new.flv',
                            'multirates': [
                              {'rate': 0, 'name': '原画'},
                            ],
                          },
                        },
                ),
              );
            },
          ),
        );
      final quality = LivePlayQuality(
        quality: '原画',
        data: DouyuPlayData(0, ['hw-h5', 'ws-h5']),
      );
      final future = PlaybackSource.refresh(
        _FreshDouyu(),
        '123',
        quality,
        previousQualities: [quality],
      );
      if (code == -5) {
        final result = await future;
        expect(result!.qualities.single.quality, '原画');
        expect(result.urls.urls.single, 'https://fixture.invalid/new.flv');
        expect(requests.skip(1).map((r) => r['cdn']), ['hw-h5', 'ws-h5']);
        expect(requests.skip(1).every((r) => r['rate'] == '0'), isTrue);
      } else {
        await expectLater(future, throwsA(isA<DouyuPlayException>()));
        expect(requests, hasLength(1));
      }
    });
  }
}
