import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/modules/mine/account/platform_web_login_policy.dart';
import 'package:simple_live_core/simple_live_core.dart';

void main() {
  for (final tokenHost in ['huya.com', 'www.huya.com']) {
    test('collector accepts modern Huya pair from $tokenHost and deduplicates',
        () async {
      final requested = <Uri>[];
      final header = await collectOfficialAccountCookieHeader(
        'huya',
        readCookies: (uri) async {
          requested.add(uri);
          return [
            const OfficialWebCookie(
                name: 'udb_uid', value: '12345', domain: '.huya.com'),
            if (uri.host == tokenHost)
              const OfficialWebCookie(
                  name: 'udb_biztoken',
                  value: 'synthetic-token',
                  domain: '.huya.com'),
            const OfficialWebCookie(
                name: 'sessionid',
                value: 'foreign-token',
                domain: '.douyin.com'),
            const OfficialWebCookie(
                name: 'foreign',
                value: 'foreign-token',
                domain: 'huya.com.attacker.invalid'),
          ];
        },
      );
      expect(requested.map((uri) => uri.toString()),
          ['https://huya.com/', 'https://www.huya.com/']);
      expect(header, 'udb_uid=12345; udb_biztoken=synthetic-token');
      expect('udb_uid='.allMatches(header!), hasLength(1));
    });
  }

  test('collector rejects incomplete Huya pairs and identity-only cookies',
      () async {
    for (final cookies in [
      [
        const OfficialWebCookie(
            name: 'udb_uid', value: '12345', domain: '.huya.com'),
      ],
      [
        const OfficialWebCookie(
            name: 'udb_biztoken',
            value: 'synthetic-token',
            domain: '.huya.com'),
      ],
      [
        const OfficialWebCookie(
            name: 'udb_uid', value: '12345', domain: '.huya.com'),
        const OfficialWebCookie(
            name: 'udb_biztoken', value: '', domain: '.huya.com'),
      ],
      [
        const OfficialWebCookie(
            name: 'yyuid', value: '12345', domain: '.huya.com'),
      ],
      [
        const OfficialWebCookie(
            name: 'udb_uid', value: '12345', domain: '.huya.com'),
        const OfficialWebCookie(
            name: 'udb_biztoken',
            value: 'foreign-token',
            domain: '.douyin.com'),
      ],
    ]) {
      expect(
          await collectOfficialAccountCookieHeader('huya',
              readCookies: (_) async => cookies),
          isNull);
    }
  });

  test('collector rejects unknown platforms before reading any cookies',
      () async {
    var calls = 0;
    await expectLater(
        collectOfficialAccountCookieHeader('unknown-private-input',
            readCookies: (_) async {
          calls++;
          return [];
        }),
        throwsA(isA<PlatformWebCookieCollectionException>()
            .having((error) => error.failure, 'failure',
                PlatformWebCookieCollectionFailure.format)
            .having((error) => error.toString(), 'message',
                isNot(contains('unknown-private-input')))));
    expect(calls, 0);
  });

  test('collector read failures never expose native credential details',
      () async {
    await expectLater(
        collectOfficialAccountCookieHeader('huya', readCookies: (_) async {
          throw StateError('synthetic-private-token');
        }),
        throwsA(isA<PlatformWebCookieCollectionException>()
            .having((error) => error.failure, 'failure',
                PlatformWebCookieCollectionFailure.read)
            .having((error) => error.toString(), 'message',
                isNot(contains('synthetic-private-token')))));
  });

  test('unsupported auxiliary cookies do not poison a valid Douyin session',
      () async {
    const auxiliaryNames = [
      '',
      'aux name',
      'aux:name',
      'aux(name)',
      'aux,name',
      'aux/name',
      'aux"name',
      'aux[name]',
      '名称',
    ];
    for (final name in auxiliaryNames) {
      expect(PlatformCookie.isValidName(name), isFalse);
      // Strict manual-header parsing is preserved; only the browser adapter
      // skips entries that cannot be represented in the imported header.
      expect(() => PlatformCookie.parse('$name=synthetic-auxiliary'),
          throwsFormatException);
    }
    final requested = <String>[];
    final header = await collectOfficialAccountCookieHeader('douyin',
        readCookies: (uri) async {
      requested.add(uri.toString());
      return [
        const OfficialWebCookie(
            name: 'sessionid',
            value: 'synthetic-token==',
            domain: '.douyin.com'),
        const OfficialWebCookie(
            name: 'passport_csrf_token',
            value: 'synthetic%2Bmetadata',
            domain: '.douyin.com'),
        for (final name in auxiliaryNames)
          OfficialWebCookie(
              name: name, value: 'synthetic-auxiliary', domain: '.douyin.com'),
        const OfficialWebCookie(
            name: 'sessionid', value: 'foreign-token', domain: '.huya.com'),
      ];
    });
    expect(requested, ['https://douyin.com/', 'https://www.douyin.com/']);
    expect(header,
        'sessionid=synthetic-token==; passport_csrf_token=synthetic%2Bmetadata');
  });

  test('unsupported native names cannot be normalized into account markers',
      () {
    for (final name in ['', ' sessionid', 'sessionid ', 'sessionid=forged']) {
      expect(
          officialAccountCookieHeader('douyin', [
            OfficialWebCookie(
                name: name,
                value: 'synthetic-auxiliary',
                domain: '.douyin.com'),
            const OfficialWebCookie(
                name: 'ttwid',
                value: 'synthetic-device',
                domain: '.douyin.com'),
          ]),
          isNull);
    }
  });

  test('a failed second scope read does not import a partial account header',
      () async {
    await expectLater(
        collectOfficialAccountCookieHeader('douyin', readCookies: (uri) async {
          if (uri.host.startsWith('www.')) {
            throw const FormatException('synthetic-private-native-response');
          }
          return const [
            OfficialWebCookie(
                name: 'sessionid',
                value: 'synthetic-token',
                domain: '.douyin.com')
          ];
        }),
        throwsA(isA<PlatformWebCookieCollectionException>()
            .having((error) => error.failure, 'failure',
                PlatformWebCookieCollectionFailure.read)
            .having((error) => error.toString(), 'message',
                isNot(contains('synthetic-private-native-response')))));
  });

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
