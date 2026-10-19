import 'dart:async';

/// Local startup diagnostics. Durations contain no account or device data.
/// The total starts at Dart entry and ends at the first rasterized app frame;
/// it does not include process/engine launch or network-loaded home content.
class StartupTimings {
  final Stopwatch _total = Stopwatch()..start();
  final Map<String, int> _stages = {};
  int? _firstFrameUs;

  Future<T> measure<T>(String stage, Future<T> Function() action) async {
    final watch = Stopwatch()..start();
    try {
      return await action();
    } finally {
      _stages[stage] = watch.elapsedMicroseconds;
    }
  }

  T measureSync<T>(String stage, T Function() action) {
    final watch = Stopwatch()..start();
    try {
      return action();
    } finally {
      _stages[stage] = watch.elapsedMicroseconds;
    }
  }

  void firstFrameRasterized() {
    _firstFrameUs ??= _total.elapsedMicroseconds;
    _total.stop();
  }

  Map<String, Object?> toJson() => {
        'dartToFirstFrameMs':
            _firstFrameUs == null ? null : _firstFrameUs! / 1000,
        // Some stages run concurrently; their durations must not be summed.
        'stagesMs': _stages.map((name, us) => MapEntry(name, us / 1000)),
      };
}
