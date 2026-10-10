/// Short-term retries and recurring line failures have separate lifetimes.
/// Controllers scope this state to a room/quality/account selection and clear
/// it on explicit changes. A healthy minute only replenishes the retry budget.
class PlaybackRecovery {
  static const _failureMemory = Duration(minutes: 15);
  int attempts = 0;
  bool stopped = false;
  String selectionReason = 'preferred';
  final Map<String, _LineFailure> _failedLines = {};

  Duration get retryDelay =>
      Duration(seconds: attempts == 0 ? 0 : (1 << attempts.clamp(1, 3)));

  void reset({bool clearLines = true}) {
    attempts = 0;
    stopped = false;
    if (clearLines) {
      _failedLines.clear();
      selectionReason = 'preferred';
    }
  }

  void failed(String? identity, DateTime now) {
    _prune(now);
    if (identity != null) {
      final recurring = _failedLines.containsKey(identity);
      _failedLines[identity] = _LineFailure(
        lastFailure: now,
        cooldownUntil: now.add(
          recurring ? _failureMemory : const Duration(minutes: 2),
        ),
        recurring: recurring,
      );
    }
  }

  void _prune(DateTime now) {
    _failedLines.removeWhere(
      (_, failure) => !now.isBefore(failure.lastFailure.add(_failureMemory)),
    );
  }

  bool hasRecurringFailure(String? identity, DateTime now) {
    _prune(now);
    return _failedLines[identity]?.recurring ?? false;
  }

  int selectLine(List<String> identities, String? current, DateTime now) {
    if (identities.isEmpty) return 0;
    _prune(now);
    final selected = identities.indexOf(current ?? '');
    final recurring = _failedLines[current]?.recurring ?? false;
    // Renew an isolated expired URL once. A healthy minute must not turn a
    // CDN that disconnects every five minutes into a first-time failure again.
    if (attempts <= 1 && selected >= 0 && !recurring) {
      selectionReason = 'renew-current';
      return selected;
    }
    final start = selected < 0 ? 0 : (selected + 1) % identities.length;
    for (var offset = 0; offset < identities.length; offset++) {
      final index = (start + offset) % identities.length;
      final failure = _failedLines[identities[index]];
      if (failure == null || !now.isBefore(failure.cooldownUntil)) {
        selectionReason = recurring ? 'avoid-recurring' : 'alternative';
        return index;
      }
    }
    // All alternatives failed recently. The bounded budget/backoff still
    // applies; choose the least recently failed line, rather than cycling.
    var oldest = start;
    for (var i = 0; i < identities.length; i++) {
      if (_failedLines[identities[i]]!.lastFailure.isBefore(
        _failedLines[identities[oldest]]!.lastFailure,
      )) {
        oldest = i;
      }
    }
    selectionReason = identities.length == 1
        ? 'only-line'
        : 'all-lines-cooling';
    return oldest;
  }
}

class _LineFailure {
  final DateTime lastFailure;
  final DateTime cooldownUntil;
  final bool recurring;
  const _LineFailure({
    required this.lastFailure,
    required this.cooldownUntil,
    required this.recurring,
  });
}

class PlaybackHealth {
  final bool progressing;
  final bool stable;
  final bool decoderStalled;
  const PlaybackHealth({
    this.progressing = false,
    this.stable = false,
    this.decoderStalled = false,
  });
}

/// One sample per second is sufficient; native state flags alone are not proof
/// of playback. Sustained decoder errors also matter: the audio clock can keep
/// moving while video decoding fails. Do not treat mpv's estimated frame count
/// (derived from that clock) as evidence that video frames are being produced.
class PlaybackHealthMonitor {
  DateTime? _sampleAt;
  Duration? _position;
  DateTime? _progressAt;
  DateTime? _stableSince;
  DateTime? _decoderSince;
  DateTime? _decoderAt;
  int _decoderErrors = 0;

  void reset() {
    _sampleAt = null;
    _position = null;
    _progressAt = null;
    _stableSince = null;
    _decoderSince = null;
    _decoderAt = null;
    _decoderErrors = 0;
  }

  void decoderError(DateTime now) {
    if (_decoderAt == null ||
        now.difference(_decoderAt!) > const Duration(seconds: 3)) {
      _decoderSince = now;
      _decoderErrors = 0;
    }
    _decoderAt = now;
    _decoderErrors++;
  }

  PlaybackHealth sample({
    required DateTime now,
    required Duration position,
    required bool playing,
    required bool buffering,
    required bool completed,
    bool suspended = false,
  }) {
    if (suspended || !playing || completed) {
      reset();
      return const PlaybackHealth();
    }
    final elapsed = _sampleAt == null ? null : now.difference(_sampleAt!);
    // Sleep/resume or a busy UI thread must not manufacture a healthy minute
    // or a decoder-stall decision from the wall-clock gap.
    if (elapsed != null &&
        (elapsed.isNegative || elapsed > const Duration(seconds: 3))) {
      reset();
    }
    final previous = _position;
    final advanced = previous != null && position > previous;
    _progressAt ??= now;
    if (advanced) _progressAt = now;
    final recentDecoderError =
        _decoderAt != null &&
        now.difference(_decoderAt!) <= const Duration(seconds: 3);
    final progressing = !buffering && advanced;
    final continuous =
        progressing &&
        !recentDecoderError &&
        elapsed != null &&
        position - previous <= elapsed + const Duration(seconds: 2);
    if (continuous) {
      _stableSince ??= now;
    } else {
      _stableSince = null;
    }
    final stalled =
        recentDecoderError &&
        ((_decoderErrors >= 3 &&
                now.difference(_decoderSince!) >= const Duration(seconds: 5) &&
                now.difference(_progressAt!) >= const Duration(seconds: 5)) ||
            (_decoderErrors >= 20 &&
                now.difference(_decoderSince!) >= const Duration(seconds: 10)));
    _sampleAt = now;
    _position = position;
    return PlaybackHealth(
      progressing: progressing && !recentDecoderError,
      stable:
          _stableSince != null &&
          now.difference(_stableSince!) >= const Duration(minutes: 1),
      decoderStalled: stalled,
    );
  }

  static bool isDecoderError(String prefix, String level, String text) {
    if (level != 'error' && level != 'warn' && level != 'fatal') return false;
    if (prefix == 'vd' ||
        prefix == 'ad' ||
        prefix.startsWith('ffmpeg/video') ||
        prefix.startsWith('ffmpeg/audio')) {
      return level != 'warn' || text.contains('Error while decoding');
    }
    if (prefix != 'ffmpeg') return false;
    final message = text.toLowerCase();
    return message.contains('reference count') ||
        message.contains('invalid nal unit') ||
        message.contains('missing picture') ||
        message.contains('error while decoding') ||
        message.contains('decode_slice_header error') ||
        message.contains('no frame!');
  }
}
