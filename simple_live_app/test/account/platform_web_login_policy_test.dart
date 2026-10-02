import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/modules/mine/account/platform_web_login_policy.dart';

void main() {
  test(
      'top-level official navigation stays isolated while HTTPS captcha frames remain usable',
      () {
    expect(
        isAllowedAccountNavigation(
            'douyin', Uri.parse('https://www.douyin.com/login'),
            isMainFrame: true),
        isTrue);
    expect(
        isAllowedAccountNavigation(
            'douyin', Uri.parse('https://external.invalid/login'),
            isMainFrame: true),
        isFalse);
    expect(
        isAllowedAccountNavigation('douyin', Uri.parse('https://www.huya.com/'),
            isMainFrame: true),
        isFalse);
    expect(
        isAllowedAccountNavigation(
            'douyin', Uri.parse('https://captcha-provider.invalid/challenge'),
            isMainFrame: false),
        isTrue);
    expect(
        isAllowedAccountNavigation(
            'douyin', Uri.parse('http://captcha-provider.invalid/'),
            isMainFrame: false),
        isFalse);
    expect(
        isAllowedAccountNavigation('douyin', Uri.parse('about:blank'),
            isMainFrame: false),
        isTrue);
    expect(
        isAllowedAccountNavigation('douyin', null, isMainFrame: true), isFalse);
  });

  test('official origin check rejects lookalike domains and insecure callbacks',
      () {
    expect(
        isOfficialAccountPage(
            'douyu', Uri.parse('https://passport.douyu.com/login')),
        isTrue);
    for (final url in [
      'https://douyu.com.attacker.invalid/',
      'https://notdouyu.com/',
      'https://douyu.com@attacker.invalid/',
      'http://www.douyu.com/',
      'https://www.huya.com/',
    ]) {
      expect(isOfficialAccountPage('douyu', Uri.parse(url)), isFalse);
    }
  });

  test(
      'collects only selected platform cookies and rejects foreign account markers',
      () {
    final header = officialAccountCookieHeader('douyu', [
      const OfficialWebCookie(
          name: 'acf_auth', value: 'synthetic-token', domain: '.douyu.com'),
      const OfficialWebCookie(
          name: 'dy_did', value: 'synthetic-device', domain: 'www.douyu.com'),
      const OfficialWebCookie(
          name: 'sessionid', value: 'foreign-token', domain: '.douyin.com'),
      const OfficialWebCookie(
          name: 'SESSDATA',
          value: 'foreign-token',
          domain: 'douyu.com.attacker.invalid'),
    ]);
    expect(header, 'acf_auth=synthetic-token; dy_did=synthetic-device');
    expect(
        officialAccountCookieHeader('douyu', [
          const OfficialWebCookie(
              name: 'sessionid',
              value: 'synthetic-token',
              domain: '.douyu.com'),
          const OfficialWebCookie(
              name: 'acf_uid', value: '12345', domain: '.douyu.com'),
        ]),
        isNull);
  });

  test(
      'visitor-only and empty authentication cookies never complete collection',
      () {
    expect(
        officialAccountCookieHeader('douyin', [
          const OfficialWebCookie(
              name: 'ttwid', value: 'synthetic-device', domain: '.douyin.com'),
          const OfficialWebCookie(
              name: 'sessionid', value: '', domain: '.douyin.com'),
        ]),
        isNull);
    expect(
        officialAccountCookieHeader('huya', [
          const OfficialWebCookie(
              name: 'yyuid', value: '12345', domain: '.huya.com'),
        ]),
        isNull);
  });

  test('native Android cookies may omit domain without reading foreign origins',
      () {
    expect(
        officialAccountCookieHeader('bilibili', [
          const OfficialWebCookie(name: 'SESSDATA', value: 'synthetic-token'),
        ]),
        'SESSDATA=synthetic-token');
  });

  test('malformed cookie values cannot inject account markers into header', () {
    expect(
        officialAccountCookieHeader('douyin', [
          const OfficialWebCookie(
              name: 'ttwid',
              value: 'guest; sessionid=injected',
              domain: '.douyin.com'),
          const OfficialWebCookie(
              name: 'sessionid', value: 'bad\r\nvalue', domain: '.douyin.com'),
        ]),
        isNull);
  });
}
