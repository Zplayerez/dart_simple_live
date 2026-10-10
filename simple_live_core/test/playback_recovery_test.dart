import 'package:simple_live_core/simple_live_core.dart';
import 'package:test/test.dart';

void main() {
  final start = DateTime.utc(2026, 10, 7);

  test('playing flags without progress never grant another retry budget', () {
    final monitor = PlaybackHealthMonitor();
    for (var second = 0; second < 180; second++) {
      final health = monitor.sample(
        now: start.add(Duration(seconds: second)),
        position: Duration.zero,
        playing: true,
        buffering: false,
        completed: false,
      );
      expect(health.stable, isFalse);
    }
  });

  test(
    'short recovery and repeated stalls cannot manufacture a healthy minute',
    () {
      final monitor = PlaybackHealthMonitor();
      var position = Duration.zero;
      for (var second = 0; second < 180; second++) {
        if (second % 20 != 0) position += const Duration(seconds: 1);
        final health = monitor.sample(
          now: start.add(Duration(seconds: second)),
          position: position,
          playing: true,
          buffering: second % 20 == 0,
          completed: false,
        );
        expect(health.stable, isFalse);
      }
    },
  );

  test('a measured minute of progress is healthy, a sleep gap is not', () {
    final monitor = PlaybackHealthMonitor();
    PlaybackHealth health = const PlaybackHealth();
    for (var second = 0; second <= 61; second++) {
      health = monitor.sample(
        now: start.add(Duration(seconds: second)),
        position: Duration(seconds: second),
        playing: true,
        buffering: false,
        completed: false,
      );
    }
    expect(health.stable, isTrue);
    health = monitor.sample(
      now: start.add(const Duration(hours: 1)),
      position: const Duration(hours: 1),
      playing: true,
      buffering: false,
      completed: false,
    );
    expect(health.stable, isFalse);
  });

  test('a timestamp discontinuity resets the healthy observation window', () {
    final monitor = PlaybackHealthMonitor();
    for (var second = 0; second < 90; second++) {
      final health = monitor.sample(
        now: start.add(Duration(seconds: second)),
        position: Duration(seconds: second + (second >= 50 ? 30 : 0)),
        playing: true,
        buffering: false,
        completed: false,
      );
      expect(health.stable, isFalse);
    }
  });

  test('isolated corrupt frames do not interrupt advancing playback', () {
    final monitor = PlaybackHealthMonitor();
    for (var second = 0; second < 90; second++) {
      final now = start.add(Duration(seconds: second));
      if (second % 15 == 0) monitor.decoderError(now);
      final health = monitor.sample(
        now: now,
        position: Duration(seconds: second),
        playing: true,
        buffering: false,
        completed: false,
      );
      expect(health.decoderStalled, isFalse);
    }
  });

  test(
    'persistent decode errors recover even while the audio clock advances',
    () {
      final monitor = PlaybackHealthMonitor();
      PlaybackHealth health = const PlaybackHealth();
      for (var second = 0; second <= 10; second++) {
        final now = start.add(Duration(seconds: second));
        for (var error = 0; error < 15; error++) {
          monitor.decoderError(now);
        }
        health = monitor.sample(
          now: now,
          position: Duration(seconds: second),
          playing: true,
          buffering: false,
          completed: false,
        );
        if (second < 10) expect(health.decoderStalled, isFalse);
        expect(health.stable, isFalse);
      }
      expect(health.decoderStalled, isTrue);
    },
  );

  test('paused or background playback does not recover from decoder logs', () {
    for (final background in [false, true]) {
      final monitor = PlaybackHealthMonitor();
      for (var second = 0; second < 60; second++) {
        final now = start.add(Duration(seconds: second));
        for (var error = 0; error < 20; error++) {
          monitor.decoderError(now);
        }
        final health = monitor.sample(
          now: now,
          position: Duration.zero,
          playing: background,
          buffering: false,
          completed: false,
          suspended: background,
        );
        expect(health.decoderStalled, isFalse);
        expect(health.stable, isFalse);
      }
    }
  });

  test(
    'decoder classification excludes cache, timestamps and network warnings',
    () {
      expect(
        PlaybackHealthMonitor.isDecoderError(
          'ffmpeg',
          'error',
          'NULL: reference count 1 overflow',
        ),
        isTrue,
      );
      expect(
        PlaybackHealthMonitor.isDecoderError(
          'vd',
          'warn',
          'Error while decoding frame (hardware decoding)!',
        ),
        isTrue,
      );
      for (final entry in [
        ('lavf', 'error', 'Failed to create file cache.'),
        ('ffmpeg', 'error', 'tcp: connection reset'),
        ('cplayer', 'warn', 'Audio device underrun detected.'),
        ('ad', 'warn', 'Invalid audio PTS: 3.8 -> 33.8'),
      ]) {
        expect(
          PlaybackHealthMonitor.isDecoderError(entry.$1, entry.$2, entry.$3),
          isFalse,
        );
      }
    },
  );

  test(
    'source renewal happens once, then failed CDN identities are avoided',
    () {
      final recovery = PlaybackRecovery()..failed('a/flv', start);
      recovery.attempts = 1;
      expect(
        recovery.selectLine(['a/flv', 'b/flv', 'c/flv'], 'a/flv', start),
        0,
      );
      recovery.attempts = 2;
      expect(
        recovery.selectLine(['c/flv', 'a/flv', 'b/flv'], 'a/flv', start),
        2,
      );
      recovery.failed('b/flv', start.add(const Duration(seconds: 8)));
      recovery.attempts = 3;
      expect(
        recovery.selectLine(['a/flv', 'c/flv', 'b/flv'], 'b/flv', start),
        1,
      );
      // With all lines cooling down, try the least recently failed line.
      recovery.failed('c/flv', start.add(const Duration(seconds: 16)));
      expect(
        recovery.selectLine(['c/flv', 'a/flv', 'b/flv'], 'c/flv', start),
        1,
      );
    },
  );

  test('retry backoff is capped and explicit reset clears failed lines', () {
    final recovery = PlaybackRecovery();
    expect(
      [
        for (var attempt = 0; attempt < 5; attempt++)
          (recovery..attempts = attempt).retryDelay.inSeconds,
      ],
      [0, 2, 4, 8, 8],
    );
    recovery.failed('b/flv', start);
    recovery.stopped = true;
    recovery.reset();
    expect(recovery.attempts, 0);
    expect(recovery.stopped, isFalse);
    recovery.attempts = 2;
    expect(recovery.selectLine(['a/flv', 'b/flv'], 'a/flv', start), 1);
  });

  test(
    'a healthy minute does not forgive a CDN that fails every five minutes',
    () {
      final recovery = PlaybackRecovery();
      recovery.failed('a/flv', start);
      recovery.attempts = 1;
      expect(recovery.selectLine(['a/flv', 'b/flv'], 'a/flv', start), 0);
      recovery.reset(clearLines: false);
      final again = start.add(const Duration(minutes: 5));
      recovery.failed('a/flv', again);
      recovery.attempts = 1;
      expect(recovery.selectLine(['b/flv', 'a/flv'], 'a/flv', again), 0);
      expect(recovery.hasRecurringFailure('a/flv', again), isTrue);
      expect(recovery.selectionReason, 'avoid-recurring');
    },
  );

  test(
    'recurring CDN cooldown survives while isolated failures become usable',
    () {
      final recovery = PlaybackRecovery();
      recovery.failed('a/flv', start);
      recovery.reset(clearLines: false);
      recovery.failed('a/flv', start.add(const Duration(minutes: 5)));
      recovery.failed('b/flv', start.add(const Duration(minutes: 6)));
      recovery.attempts = 2;
      final later = start.add(const Duration(minutes: 9));
      expect(
        recovery.selectLine(['a/flv', 'b/flv', 'c/flv'], 'c/flv', later),
        1,
      );
      expect(recovery.hasRecurringFailure('a/flv', later), isTrue);
    },
  );

  test('a CDN gets another renewal after fifteen minutes without failure', () {
    final recovery = PlaybackRecovery();
    recovery.failed('a/flv', start);
    recovery.failed('a/flv', start.add(const Duration(minutes: 5)));
    recovery.reset(clearLines: false);
    final later = start.add(const Duration(minutes: 21));
    recovery.failed('a/flv', later);
    recovery.attempts = 1;
    expect(recovery.selectLine(['a/flv', 'b/flv'], 'a/flv', later), 0);
    expect(recovery.hasRecurringFailure('a/flv', later), isFalse);
    expect(recovery.selectionReason, 'renew-current');
  });

  test(
    'explicit selection reset removes recurring failures as well as retries',
    () {
      final recovery = PlaybackRecovery();
      recovery.failed('a/flv', start);
      final again = start.add(const Duration(minutes: 5));
      recovery.failed('a/flv', again);
      recovery.reset();
      recovery.failed('a/flv', again);
      recovery.attempts = 1;
      expect(recovery.selectLine(['a/flv', 'b/flv'], 'a/flv', again), 0);
      expect(recovery.hasRecurringFailure('a/flv', again), isFalse);
    },
  );

  test(
    'an only available recurring line can still renew within the retry budget',
    () {
      final recovery = PlaybackRecovery();
      recovery.failed('a/flv', start);
      recovery.reset(clearLines: false);
      final again = start.add(const Duration(minutes: 5));
      recovery.failed('a/flv', again);
      recovery.attempts = 1;
      expect(recovery.selectLine(['a/flv'], 'a/flv', again), 0);
      expect(recovery.selectionReason, 'only-line');
      expect(recovery.retryDelay, const Duration(seconds: 2));
    },
  );
}
