/// Last-line protection for diagnostic sinks. HTTP bodies and headers must not
/// be logged at all: arbitrary JavaScript may contain unnamed credentials.
class LogRedactor {
  // Share the credential key catalog between unstructured and structured logs.
  // Provider cookie names also occur on their own in browser/native errors.
  static const _credentialFields =
      r'cookie|set-cookie|authorization|sessdata|bili_jct|acf_[a-z0-9_]+|udb_[a-z0-9_]+|ttwid|sessionid(?:_ss)?|sid_tt|mstoken|access_token|refresh_token|access_key|auth_code|qrcode_key|qrcodekey|oauth_key|oauthkey|token|sign|signature|wssecret|a_bogus';

  static String redactUri(Uri uri) {
    if (!uri.hasScheme) return '[redacted-uri]';
    return '${uri.scheme}://${uri.host}${uri.hasPort ? ':${uri.port}' : ''}/[redacted-path]';
  }

  static String redact(String value) {
    var safe = value.replaceAllMapped(
      RegExp(r'''(?:https?|wss?)://[^\s<>"']+''', caseSensitive: false),
      (m) => redactUri(Uri.tryParse(m.group(0)!) ?? Uri()),
    );
    safe = safe.replaceAllMapped(
      RegExp(
        r'''["']?(?:''' + _credentialFields + r''')["']?\s*[:=：]\s*[^\r\n]*''',
        caseSensitive: false,
      ),
      (_) => '[credential redacted]',
    );
    return safe;
  }

  static Object? structured(Object? value) {
    if (value is Map) {
      return value.map(
        (key, item) => MapEntry(
          key.toString(),
          RegExp(
                _credentialFields +
                    r'|auth|token|sign|secret|password|credential|qr.*key',
                caseSensitive: false,
              ).hasMatch(key.toString())
              ? '[redacted]'
              : structured(item),
        ),
      );
    }
    if (value is Iterable) return value.map(structured).toList();
    return value is String ? redact(value) : value;
  }
}
