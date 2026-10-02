import 'dart:convert';

/// Metadata for one returned URL; different CDNs can downgrade independently.
class LivePlayUrlInfo {
  final String? actualQuality;
  final int? actualRate;
  final String? cdn;
  final DateTime? fetchedAt;

  /// Provider-reported lifetime; zero means no fixed expiry was reported,
  /// not a promise that the URL is permanent.
  final int? expiresInSeconds;
  final String? limitationReason;

  /// Prefer provider metadata over the requested label. A numeric rate without
  /// its display name must not be presented as the requested original quality.
  String displayedQuality(String requested) {
    final returnedName = actualQuality?.trim();
    if (returnedName != null && returnedName.isNotEmpty) return returnedName;
    if (actualRate != null) return '平台码率 $actualRate';
    return requested;
  }

  const LivePlayUrlInfo({
    this.actualQuality,
    this.actualRate,
    this.cdn,
    this.fetchedAt,
    this.expiresInSeconds,
    this.limitationReason,
  });
}

class LivePlayUrl {
  final List<String> urls;
  final Map<String, String>? headers;
  final String? actualQuality;
  final int? actualRate;
  final String? cdn;
  final DateTime? fetchedAt;
  final int? expiresInSeconds;
  final int? accountSessionVersion;
  final String? limitationReason;
  final Map<String, LivePlayUrlInfo> urlInfo;

  LivePlayUrl({
    required this.urls,
    this.headers,
    this.actualQuality,
    this.actualRate,
    this.cdn,
    this.fetchedAt,
    this.expiresInSeconds,
    this.accountSessionVersion,
    this.limitationReason,
    Map<String, LivePlayUrlInfo> urlInfo = const {},
  }) : urlInfo = Map.unmodifiable(urlInfo);

  LivePlayUrlInfo infoForUrl(String url) =>
      urlInfo[url] ??
      LivePlayUrlInfo(
        actualQuality: actualQuality,
        actualRate: actualRate,
        cdn: cdn,
        fetchedAt: fetchedAt,
        expiresInSeconds: expiresInSeconds,
        limitationReason: limitationReason,
      );

  @override
  String toString() => json.encode({
    'urlCount': urls.length,
    'headers': '[redacted]',
    'actualQuality': actualQuality,
    'actualRate': actualRate,
    'expiresInSeconds': expiresInSeconds,
    'accountSessionVersion': accountSessionVersion,
  });
}
