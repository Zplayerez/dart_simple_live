import 'package:simple_live_core/src/model/live_play_url.dart';
import 'package:simple_live_core/src/model/playback_refresh_policy.dart';
import 'package:test/test.dart';

void main() {
  final start = DateTime.utc(2026, 10, 2);
  test('stable and unknown sources never schedule a periodic replacement', () {
    for (final lifetime in <int?>[null, 0, -1]) {
      expect(PlaybackRefreshPolicy.prefetchDelay(LivePlayUrlInfo(
        expiresInSeconds: lifetime, fetchedAt: start), now: start), isNull);
    }
  });
  test('finite source prefetch uses age and the actual selected CDN', () {
    final urls = LivePlayUrl(urls: ['stable', 'limited'], urlInfo: {
      'stable': LivePlayUrlInfo(expiresInSeconds: 0, fetchedAt: start),
      'limited': LivePlayUrlInfo(expiresInSeconds: 300, fetchedAt: start),
    });
    expect(PlaybackRefreshPolicy.prefetchDelay(urls.infoForUrl('stable'), now: start), isNull);
    expect(PlaybackRefreshPolicy.prefetchDelay(urls.infoForUrl('limited'),
      now: start.add(const Duration(minutes: 2))), const Duration(seconds: 150));
    expect(PlaybackRefreshPolicy.prefetchDelay(urls.infoForUrl('limited'),
      now: start.add(const Duration(minutes: 6))), Duration.zero);
  });
  test('stale prefetch and expired URLs cannot be reopened', () {
    final limited = LivePlayUrlInfo(expiresInSeconds: 10, fetchedAt: start);
    expect(PlaybackRefreshPolicy.canUsePrefetched(limited, start,
      now: start.add(const Duration(seconds: 9))), isTrue);
    expect(PlaybackRefreshPolicy.canUsePrefetched(limited, start,
      now: start.add(const Duration(seconds: 10))), isFalse);
    final stable = LivePlayUrlInfo(expiresInSeconds: 0, fetchedAt: start);
    expect(PlaybackRefreshPolicy.canUsePrefetched(stable, start,
      now: start.add(const Duration(minutes: 2))), isFalse);
  });
}
