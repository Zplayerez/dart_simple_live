/// Only explicit transport failures bypass the normal buffering grace period.
/// Never classify decoder/timestamp warnings, or arbitrary URL query contents.
class PlaybackFailure {
  final String reason;
  final String? host;
  const PlaybackFailure(this.reason, {this.host});

  bool get fast => reason != 'native-error';

  static PlaybackFailure parse(String error) {
    final url = RegExp(r'https?://[^\s)]+').firstMatch(error)?.group(0);
    final withoutUrls = error.replaceAll(RegExp(r'https?://\S+'), '');
    final dns = RegExp(
      r'(?:failed to resolve hostname|could not resolve host:)\s*([^\s:]+)',
      caseSensitive: false,
    ).firstMatch(withoutUrls);
    final parsedHost = dns?.group(1) ?? Uri.tryParse(url ?? '')?.host;
    final host = parsedHost?.isNotEmpty == true
        ? parsedHost!.toLowerCase()
        : null;
    final text = withoutUrls.toLowerCase();
    if (dns != null || text.contains('temporary failure in name resolution')) {
      return PlaybackFailure('dns-error', host: host);
    }
    if (text.contains('connection refused') ||
        text.contains('network is unreachable') ||
        text.contains('no route to host')) {
      return PlaybackFailure('connect-error', host: host);
    }
    if (RegExp(r'http error (?:403|404|410|5\d\d)\b').hasMatch(text)) {
      return PlaybackFailure('http-error', host: host);
    }
    return PlaybackFailure('native-error', host: host);
  }

  static bool isFastReason(String reason) =>
      const {'dns-error', 'connect-error', 'http-error'}.contains(reason);
}
