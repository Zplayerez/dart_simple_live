import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/modules/mine/account/platform_web_cookie_cleanup.dart';

void main() {
  test(
      'logout deletes selected platform cookies at exact domain and nonroot path',
      () async {
    final cookies = [
      Cookie(
          name: 'SESSDATA',
          value: 'synthetic',
          domain: '.bilibili.com',
          path: '/'),
      Cookie(
          name: 'auth',
          value: 'synthetic',
          domain: 'passport.bilibili.com',
          path: '/login'),
      Cookie(
          name: 'nested',
          value: 'synthetic',
          domain: '.a.b.bilibili.com',
          path: '/passport/confirm/'),
      Cookie(
          name: 'sessionid',
          value: 'synthetic-other',
          domain: '.douyin.com',
          path: '/'),
      Cookie(
          name: 'foreign',
          value: 'synthetic-other',
          domain: 'bilibili.com.attacker.invalid',
          path: '/'),
    ];
    final removed = <String>[];
    await clearEnumeratedPlatformWebCookies(
      'bilibili',
      readCookies: () async => List.of(cookies),
      deleteCookie: (cookie) async {
        removed.add('${cookie.name}|${cookie.domain}|${cookie.path}');
        cookies.remove(cookie);
        return true;
      },
    );
    expect(removed, [
      'SESSDATA|.bilibili.com|/',
      'auth|passport.bilibili.com|/login',
      'nested|.a.b.bilibili.com|/passport/confirm/',
    ]);
    expect(cookies.map((cookie) => cookie.name), ['sessionid', 'foreign']);
  });

  test('native false return cannot be reported as successful logout cleanup',
      () async {
    await expectLater(
        clearEnumeratedPlatformWebCookies(
          'douyin',
          readCookies: () async => [
            Cookie(
                name: 'sessionid',
                value: 'synthetic',
                domain: '.douyin.com',
                path: '/')
          ],
          deleteCookie: (_) async => false,
        ),
        throwsStateError);
  });

  test('readback detects native success without actual deletion', () async {
    await expectLater(
        clearEnumeratedPlatformWebCookies(
          'douyin',
          readCookies: () async => [
            Cookie(
                name: 'sessionid',
                value: 'synthetic',
                domain: '.douyin.com',
                path: '/passport/')
          ],
          deleteCookie: (_) async => true,
        ),
        throwsStateError);
  });
}
