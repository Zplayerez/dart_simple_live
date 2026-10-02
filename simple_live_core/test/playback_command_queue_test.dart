import 'dart:async';

import 'package:simple_live_core/src/common/playback_command_queue.dart';
import 'package:test/test.dart';

void main() {
  test(
    'mutations are serialized until the previous async command completes',
    () async {
      final queue = PlaybackCommandQueue();
      final firstStarted = Completer<void>();
      final releaseFirst = Completer<void>();
      final events = <String>[];
      final first = queue.run(
        isCurrent: () => true,
        command: () async {
          events.add('first:start');
          firstStarted.complete();
          await releaseFirst.future;
          events.add('first:end');
        },
      );
      final second = queue.run(
        isCurrent: () => true,
        command: () async {
          events.add('second');
        },
      );
      await firstStarted.future;
      expect(events, ['first:start']);
      releaseFirst.complete();
      expect(await first, isTrue);
      expect(await second, isTrue);
      expect(events, ['first:start', 'first:end', 'second']);
    },
  );

  test(
    'room or account change discards old waiting commands and runs newest',
    () async {
      final queue = PlaybackCommandQueue();
      final firstStarted = Completer<void>();
      final releaseFirst = Completer<void>();
      var revision = 1;
      final played = <String>[];
      final first = queue.run(
        isCurrent: () => revision == 1,
        command: () async {
          firstStarted.complete();
          await releaseFirst.future;
          // Mirrors the controller guard after player initialization.
          if (revision == 1) played.add('old-running');
        },
      );
      final stale = queue.run(
        isCurrent: () => revision == 1,
        command: () async {
          played.add('old-queued');
        },
      );
      await firstStarted.future;
      revision = 2;
      final latest = queue.run(
        isCurrent: () => revision == 2,
        command: () async {
          played.add('new');
        },
      );
      releaseFirst.complete();
      expect(await first, isFalse);
      expect(await stale, isFalse);
      expect(await latest, isTrue);
      expect(played, ['new']);
    },
  );

  test(
    'an already closed player skips commands without invoking native work',
    () async {
      final queue = PlaybackCommandQueue();
      var invoked = false;
      expect(
        await queue.run(
          isCurrent: () => false,
          command: () async {
            invoked = true;
          },
        ),
        isFalse,
      );
      expect(invoked, isFalse);
    },
  );

  test(
    'native command error reaches caller while later commands still run',
    () async {
      final queue = PlaybackCommandQueue();
      final firstStarted = Completer<void>();
      final failFirst = Completer<void>();
      final failure = StateError('synthetic native failure');
      var recovered = false;
      final first = queue.run(
        isCurrent: () => true,
        command: () async {
          firstStarted.complete();
          await failFirst.future;
          throw failure;
        },
      );
      final observed = expectLater(first, throwsA(same(failure)));
      final next = queue.run(
        isCurrent: () => true,
        command: () async {
          recovered = true;
        },
      );
      await firstStarted.future;
      expect(recovered, isFalse);
      failFirst.complete();
      await observed;
      expect(await next, isTrue);
      expect(recovered, isTrue);
    },
  );

  test(
    'a throwing generation predicate also cannot poison the queue',
    () async {
      final queue = PlaybackCommandQueue();
      var invoked = false;
      await expectLater(
        queue.run(
          isCurrent: () => throw StateError('disposed owner'),
          command: () async {
            invoked = true;
          },
        ),
        throwsStateError,
      );
      expect(invoked, isFalse);
      expect(
        await queue.run(isCurrent: () => true, command: () async {}),
        isTrue,
      );
    },
  );
}
