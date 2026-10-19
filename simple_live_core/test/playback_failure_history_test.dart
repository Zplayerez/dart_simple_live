import 'package:simple_live_core/simple_live_core.dart';
import 'package:test/test.dart';

void main() {
  final now = DateTime.utc(2026, 10, 19);
  LivePlayUrl sources(List<String> hosts) => LivePlayUrl(
    urls: [
      for (final host in hosts) 'https://$host/live.flv?signature=synthetic',
    ],
  );

  test('only explicit transport failures bypass the buffering grace', () {
    final dns = PlaybackFailure.parse(
      'tcp: Failed to resolve hostname '
      'hw3.douyucdn2.cn: Temporary failure in name resolution',
    );
    expect(dns.reason, 'dns-error');
    expect(dns.host, 'hw3.douyucdn2.cn');
    expect(PlaybackFailure.parse('tcp: Connection refused').fast, isTrue);
    expect(
      PlaybackFailure.parse('http: HTTP error 404 Not Found').fast,
      isTrue,
    );
    expect(
      PlaybackFailure.parse('http: HTTP error 404 Not Found').host,
      isNull,
    );
    for (final text in [
      'NULL: Invalid NAL unit size (12 > 3)',
      'Invalid audio PTS: 2 -> 4200000',
      'http: Stream ends prematurely',
      'Failed to open https://old.invalid/live.flv?HTTP-error-404',
      'Failed to open https://old.invalid/?Connection%20refused',
    ]) {
      expect(PlaybackFailure.parse(text).fast, isFalse, reason: text);
    }
  });

  test('DNS failures exclude aliases on one host, not a different host', () {
    final history = PlaybackLineHistory();
    final urls = [
      'https://a.invalid/1.flv',
      'https://a.invalid/2.flv',
      'https://b.invalid/1.flv',
      'https://c.invalid/1.flv',
    ];
    final result = LivePlayUrl(
      urls: urls,
      urlInfo: {
        urls[0]: const LivePlayUrlInfo(cdn: 'hw'),
        urls[1]: const LivePlayUrlInfo(cdn: 'another-alias'),
        urls[2]: const LivePlayUrlInfo(cdn: 'hw'),
      },
    );
    history.failed('room', result, urls[0], now, dns: true);
    expect(history.available('room', result, now), [2, 3]);
    expect(history.select('room', result, 'hw/flv', now), 2);
    expect(history.available('other-room', result, now), [0, 1, 2, 3]);
  });

  test(
    'failure history survives source renewal and expires after ten minutes',
    () {
      final history = PlaybackLineHistory();
      final initial = sources(['a.invalid', 'b.invalid']);
      history.failed('room', initial, initial.urls.first, now, dns: true);
      final renewed = LivePlayUrl(
        urls: [
          'https://a.invalid/new.flv?signature=new',
          'https://b.invalid/new.flv?signature=new',
        ],
      );
      expect(history.select('room', renewed, 'a.invalid/flv', now), 1);
      expect(
        history.select(
          'room',
          renewed,
          'a.invalid/flv',
          now.add(const Duration(minutes: 10)),
        ),
        0,
      );
    },
  );

  test(
    'verified healthy selection is remembered, without storing signed URLs',
    () {
      final history = PlaybackLineHistory();
      final result = sources(['a.invalid', 'b.invalid']);
      history.failed('room', result, result.urls[1], now, dns: true);
      history.healthy('room', result, result.urls[1], now);
      expect(history.available('room', result, now), [0, 1]);
      expect(history.select('room', result, null, now), 1);
      expect(history.select('room', result, 'removed/flv', now), 1);
      expect(history.select('room', result, 'a.invalid/flv', now), 0);
    },
  );

  test('all failed candidates remain available to bounded recovery', () {
    final history = PlaybackLineHistory();
    final result = sources(['a.invalid']);
    history.failed('room', result, result.urls.single, now);
    expect(history.available('room', result, now), isEmpty);
    expect(history.select('room', result, null, now), 0);
  });

  test('history is bounded across many visited rooms', () {
    final history = PlaybackLineHistory();
    final result = sources(['a.invalid', 'b.invalid']);
    for (var i = 0; i <= PlaybackLineHistory.maxEntries; i++) {
      history.failed('room-$i', result, result.urls.first, now);
      history.healthy('room-$i', result, result.urls[1], now);
    }
    expect(history.available('room-0', result, now), [0, 1]);
    expect(history.select('room-0', result, null, now), 0);
    expect(history.available('room-256', result, now), [1]);
  });
}
