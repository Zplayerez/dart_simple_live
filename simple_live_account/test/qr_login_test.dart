import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_account/src/qr_login.dart';
import 'package:simple_live_account/src/qr_login_http.dart';

class FixtureTransport implements QrLoginTransport {
  final requests = <Uri>[];
  final responses = <Object>[];
  String cookie = '';
  bool closed = false;
  @override
  Future<Uint8List> request(
    Uri uri, {
    Map<String, String>? form,
    Map<String, dynamic>? jsonBody,
  }) async {
    requests.add(uri);
    final value = responses.removeAt(0);
    return Uint8List.fromList(
      utf8.encode(value is String ? value : jsonEncode(value)),
    );
  }

  @override
  String cookiesFor(Uri uri) => cookie;
  @override
  void close() => closed = true;
}

void main() {
  test('isolated cookies respect host, path, expiry and unrelated domains', () {
    final jar = QrCookieJar();
    final origin = Uri.parse('https://passport.douyu.com/scan/generateCode');
    jar.accept(origin, [
      Cookie.fromSetCookieValue('private=host-only; Path=/; Secure'),
      Cookie.fromSetCookieValue(
        'acf_auth=synthetic; Domain=.douyu.com; Path=/; Secure',
      ),
      Cookie.fromSetCookieValue(
        'pathOnly=value; Domain=.douyu.com; Path=/scan',
      ),
      Cookie.fromSetCookieValue('foreign=value; Domain=.huya.com; Path=/'),
      Cookie.fromSetCookieValue('super=value; Domain=com; Path=/'),
    ]);
    expect(
      jar.header(Uri.parse('https://www.douyu.com/')),
      'acf_auth=synthetic',
    );
    expect(
      jar.header(Uri.parse('https://www.douyu.com/scanner')),
      'acf_auth=synthetic',
    );
    expect(
      jar.header(Uri.parse('https://www.douyu.com/scan/auth')),
      contains('pathOnly=value'),
    );
    expect(jar.header(Uri.parse('https://www.huya.com/')), isEmpty);
    expect(jar.header(Uri.parse('http://www.douyu.com/')), isEmpty);
    jar.accept(origin, [
      Cookie.fromSetCookieValue(
        'acf_auth=deleted; Domain=.douyu.com; Path=/; Max-Age=0',
      ),
    ]);
    expect(jar.header(Uri.parse('https://www.douyu.com/')), isEmpty);
    jar.clear();
    expect(jar.header(origin), isEmpty);
  });

  test('callback destinations require exact official HTTPS hosts', () {
    for (final url in [
      'http://www.douyu.com/',
      'https://douyu.com.evil.invalid/',
      'https://www.douyu.com@evil.invalid/',
      'https://www.douyu.com:8080/',
      'https://127.0.0.1/',
      'https://www.huya.com/',
    ]) {
      expect(OfficialQrHttp.permits('douyu', Uri.parse(url)), isFalse);
    }
    expect(
      OfficialQrHttp.permits(
        'douyu',
        Uri.parse('https://www.douyu.com/member/callback'),
      ),
      isTrue,
    );
  });

  test(
    'Douyu waiting and scanned states never finish before official callback',
    () async {
      final http = FixtureTransport()..cookie = 'acf_auth=synthetic';
      http.responses.addAll([
        {
          'error': 0,
          'data': {
            'code': 'synthetic-key',
            'url': 'https://passport.douyu.com/scan/test',
            'expire': 300,
          },
        },
        {'error': -2},
        {'error': 1},
        {
          'error': 0,
          'data': {
            'url': 'https://www.douyu.com/member/callback?ticket=synthetic',
          },
        },
        'appClient_json_callback({"error":0});',
      ]);
      final session = OfficialQrLoginSession('douyu', transport: http);
      await session.generate();
      expect((await session.poll()).stage, QrLoginStage.waiting);
      expect((await session.poll()).stage, QrLoginStage.scanned);
      final result = await session.poll();
      expect(result.stage, QrLoginStage.confirmed);
      expect(result.cookie, 'acf_auth=synthetic');
      expect(
        http.requests.last.queryParameters['callback'],
        'appClient_json_callback',
      );
      expect(result.toString(), isNot(contains('synthetic')));
      session.close();
      expect(http.closed, isTrue);
    },
  );

  test(
    'Douyu rejects foreign callback without sending authorization',
    () async {
      final http = FixtureTransport()
        ..responses.addAll([
          {
            'error': 0,
            'data': {
              'code': 'fixture',
              'url': 'https://passport.douyu.com/scan/fixture',
            },
          },
          {
            'error': 0,
            'data': {'url': 'https://evil.invalid/?ticket=secret'},
          },
        ]);
      final session = OfficialQrLoginSession('douyu', transport: http);
      await session.generate();
      await expectLater(session.poll(), throwsA(isA<QrLoginException>()));
      expect(http.requests.length, 2);
    },
  );

  test(
    'Huya completes the website callback, not just the scan response',
    () async {
      final http = FixtureTransport()
        ..cookie = 'udb_uid=123; udb_biztoken=synthetic';
      http.responses.addAll([
        {
          'returnCode': '0',
          'data': {'qrId': 'fixture'},
        },
        'fixture-image',
        {
          'returnCode': '0',
          'data': {'stage': '1'},
        },
        {
          'returnCode': '0',
          'data': {
            'stage': '3',
            'loginTime': 123,
            'sign': 'fixture',
            'domainUrlList': [],
          },
        },
        '<html></html>',
      ]);
      final session = OfficialQrLoginSession('huya', transport: http);
      await session.generate();
      expect((await session.poll()).stage, QrLoginStage.scanned);
      expect((await session.poll()).stage, QrLoginStage.confirmed);
      expect(http.requests.last.host, 'l.huya.com');
      expect(http.requests.last.queryParameters['do'], 'huyaCallback');
    },
  );

  test(
    'confirmation without account cookies is not successful login',
    () async {
      final http = FixtureTransport()..cookie = 'buvid3=visitor';
      http.responses.addAll([
        {
          'code': 0,
          'data': {
            'qrcode_key': 'fixture',
            'url': 'https://www.bilibili.com/fixture',
          },
        },
        {
          'code': 0,
          'data': {'code': 0},
        },
      ]);
      final session = OfficialQrLoginSession('bilibili', transport: http);
      await session.generate();
      await expectLater(session.poll(), throwsA(isA<QrLoginException>()));
    },
  );

  test(
    'expired Bilibili code is terminal and does not return credentials',
    () async {
      final http = FixtureTransport()
        ..responses.addAll([
          {
            'code': 0,
            'data': {
              'qrcode_key': 'fixture',
              'url': 'https://www.bilibili.com/fixture',
            },
          },
          {
            'code': 0,
            'data': {'code': 86038},
          },
        ]);
      final session = OfficialQrLoginSession('bilibili', transport: http);
      await session.generate();
      final result = await session.poll();
      expect(result.stage, QrLoginStage.expired);
      expect(result.cookie, isNull);
    },
  );

  test(
    'Douyin directs users to web login without making a native QR request',
    () {
      final http = FixtureTransport();
      expect(
        () => OfficialQrLoginSession('douyin', transport: http),
        throwsA(
          isA<QrLoginException>().having(
            (e) => e.message,
            'message',
            contains('网页登录'),
          ),
        ),
      );
      expect(http.requests, isEmpty);
    },
  );
}
