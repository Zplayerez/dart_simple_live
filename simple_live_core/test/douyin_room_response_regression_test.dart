import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:simple_live_core/simple_live_core.dart';
import 'package:simple_live_core/src/common/http_client.dart';
import 'package:test/test.dart';

void main() {
  late Dio original;
  late bool logging;
  setUp(() {
    original = HttpClient.instance.dio;
    logging = CoreLog.enableLog;
    CoreLog.enableLog = false;
  });
  tearDown(() {
    HttpClient.instance.dio.close();
    HttpClient.instance.dio = original;
    CoreLog.enableLog = logging;
  });
  final room = {
    'id_str': '999',
    'status': 2,
    'title': 'fixture',
    'owner': {'nickname': 'fixture', 'avatar_thumb': null, 'signature': ''},
    'cover': {'url_list': []},
    'room_view_stats': {'display_value': 1},
    'stream_url': {},
  };
  final html =
      jsonEncode({
        'state': {
          'appStore': {},
          'userStore': {
            'odin': {'user_unique_id': '888'},
          },
          'roomStore': {
            'roomInfo': {'room': room, 'anchor': {}},
          },
        },
      }).replaceAll('"', r'\"') +
      r']\n';

  for (final body in [
    {'data': null},
    {
      'data': {'data': null},
    },
    {
      'data': {'data': []},
    },
    {
      'data': {
        'data': ['invalid'],
      },
    },
  ]) {
    test('missing room list falls back to HTML: $body', () async {
      var pages = 0;
      HttpClient.instance.dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (request, handler) {
              dynamic data = '';
              if (request.uri.path.contains('/webcast/')) {
                data = body;
              } else if (request.method != 'HEAD') {
                pages++;
                data = html;
              }
              handler.resolve(
                Response(requestOptions: request, statusCode: 200, data: data),
              );
            },
          ),
        );
      final result = await (DouyinSite()..cookie = 'ttwid=fixture')
          .getRoomDetailByWebRid('123');
      expect(result.status, isTrue);
      expect(result.title, 'fixture');
      expect(result.cover, isEmpty);
      expect(result.userAvatar, isEmpty);
      expect(pages, 1);
    });
  }

  test('missing images do not discard valid API room status', () async {
    HttpClient.instance.dio = Dio()
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (request, handler) {
            expect(request.uri.path, contains('/webcast/'));
            handler.resolve(
              Response(
                requestOptions: request,
                statusCode: 200,
                data: {
                  'data': {
                    'data': [room],
                    'user': {},
                  },
                },
              ),
            );
          },
        ),
      );
    final result = await (DouyinSite()..cookie = 'ttwid=fixture')
        .getRoomDetailByWebRid('123');
    expect(result.status, isTrue);
    expect(result.userAvatar, isEmpty);
  });
}
