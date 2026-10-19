import 'package:simple_live_core/src/model/live_play_url.dart';
import 'package:test/test.dart';

void main() {
  test('provider downgrade name wins over requested original quality', () {
    const returned = LivePlayUrlInfo(actualRate: 3, actualQuality: '4M');
    expect(returned.displayedQuality('原画1080p60'), '4M');
  });

  test(
    'unnamed returned rate never falls back to misleading original label',
    () {
      for (final rate in [0, 3, 4000]) {
        final returned = LivePlayUrlInfo(actualRate: rate, actualQuality: '  ');
        expect(returned.displayedQuality('原画'), '平台码率 $rate');
      }
    },
  );

  test(
    'legacy providers without returned quality retain their requested label',
    () {
      expect(const LivePlayUrlInfo().displayedQuality('高清'), '高清');
    },
  );

  test('selected CDN decides its own actual quality label', () {
    final sources = LivePlayUrl(
      urls: ['first', 'second'],
      actualQuality: '原画',
      urlInfo: {
        'first': const LivePlayUrlInfo(
          actualRate: 0,
          actualQuality: '原画1080p60',
        ),
        'second': const LivePlayUrlInfo(actualRate: 3),
      },
    );
    expect(sources.infoForUrl('first').displayedQuality('原画'), '原画1080p60');
    expect(sources.infoForUrl('second').displayedQuality('原画'), '平台码率 3');
  });
}
