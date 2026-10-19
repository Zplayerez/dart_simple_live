/// Serializes mutations of one player while discarding obsolete queued work.
///
/// A running command cannot be cancelled here. Callers must check [isCurrent]
/// between asynchronous player operations before opening or changing media.
class PlaybackCommandQueue {
  Future<void> _tail = Future<void>.value();

  Future<bool> run({
    required bool Function() isCurrent,
    required Future<void> Function() command,
  }) {
    final result = _tail.then<bool>((_) async {
      if (!isCurrent()) return false;
      await command();
      return isCurrent();
    });
    // Keep serialization alive after an error without hiding it from the caller.
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }
}
