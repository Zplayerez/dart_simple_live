import 'package:simple_live_core/src/common/sensitive_log.dart';
import 'package:test/test.dart';

void main() {
  test('standalone Huya login cookies are redacted without a Cookie label', () {
    for (final key in [
      'udb_l',
      'udb_n',
      'udb_oar',
      'udb_passdata',
      'udb_uid',
      'udb_biztoken',
      'udb_cred',
    ]) {
      final result = LogRedactor.redact(
        '$key=synthetic-private-value; other=value',
      );
      expect(result, isNot(contains('synthetic-private-value')), reason: key);
    }
  });

  test('structured logs redact provider credentials by field name', () {
    final result = LogRedactor.structured({
      'SESSDATA': 'synthetic-bili-value',
      'bili_jct': 'synthetic-csrf-value',
      'sessionid': 'synthetic-douyin-value',
      'udb_l': 'synthetic-huya-value',
      'udb_uid': 'synthetic-huya-user',
      'udb_biztoken': 'synthetic-huya-token',
      'udb_cred': 'synthetic-huya-restore',
      'nested': [
        {'ttwid': 'synthetic-device-value'},
      ],
      'status': 200,
    });
    expect(result.toString(), isNot(contains('synthetic-')));
    expect((result as Map)['status'], 200);
  });

  test('URI redaction strips userinfo, full path, query and fragment', () {
    final result = LogRedactor.redactUri(
      Uri.parse(
        'https://synthetic-user:synthetic-pass@official.example/synthetic-path?token=synthetic-query#synthetic-fragment',
      ),
    );
    expect(result, 'https://official.example/[redacted-path]');
  });
}
