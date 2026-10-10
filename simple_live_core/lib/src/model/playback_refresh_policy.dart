import 'live_play_url.dart';

/// Scheduling is based on the selected source, never the requested quality.
class PlaybackRefreshPolicy {
  static Duration? prefetchDelay(LivePlayUrlInfo info, {DateTime? now}) {
    final lifetime = info.expiresInSeconds;
    final fetchedAt = info.fetchedAt;
    if (lifetime == null || lifetime <= 0 || fetchedAt == null) return null;
    final leadSeconds = (lifetime ~/ 5).clamp(1, 30);
    final deadline = fetchedAt.add(Duration(seconds: lifetime - leadSeconds));
    final remaining = deadline.difference(now ?? DateTime.now());
    return remaining.isNegative ? Duration.zero : remaining;
  }

  /// Prefetched URLs are intentionally short lived even without an expiry.
  /// A zero provider lifetime is not treated as an unlimited cache lifetime.
  static bool canUsePrefetched(LivePlayUrlInfo info, DateTime receivedAt,
      {DateTime? now}) {
    final current = now ?? DateTime.now();
    final age = current.difference(receivedAt);
    if (age.isNegative || age > const Duration(minutes: 1)) return false;
    final lifetime = info.expiresInSeconds;
    if (lifetime == null || lifetime <= 0) return true;
    final fetchedAt = info.fetchedAt ?? receivedAt;
    return current.isBefore(fetchedAt.add(Duration(seconds: lifetime)));
  }
}
