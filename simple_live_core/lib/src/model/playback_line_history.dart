import 'live_play_url.dart';

/// Bounded process-local history, independent of a player's retry budget.
/// Only identities/hosts are kept: no signed URLs, cookies or account data.
class PlaybackLineHistory {
  static final shared = PlaybackLineHistory();
  static const retention = Duration(minutes: 10);
  static const maxEntries = 256;
  final _failed = <String, DateTime>{};
  final _working = <String, (String, DateTime)>{};

  void clear() {
    _failed.clear();
    _working.clear();
  }

  String _endpoint(String url) => Uri.tryParse(url)?.host.toLowerCase() ?? '';
  String _key(String scope, LivePlayUrl sources, String url) =>
      '$scope|${sources.identityForUrl(url)}|${_endpoint(url)}';

  void _prune(DateTime now) {
    _failed.removeWhere((_, at) => !now.isBefore(at.add(retention)));
    _working.removeWhere((_, value) => !now.isBefore(value.$2.add(retention)));
    while (_failed.length > maxEntries) {
      _failed.remove(_failed.keys.first);
    }
    while (_working.length > maxEntries) {
      _working.remove(_working.keys.first);
    }
  }

  void failed(
    String scope,
    LivePlayUrl sources,
    String url,
    DateTime now, {
    bool dns = false,
  }) {
    final key = dns
        ? '$scope|dns|${_endpoint(url)}'
        : _key(scope, sources, url);
    _failed.remove(key);
    _failed[key] = now;
    _prune(now);
  }

  void healthy(String scope, LivePlayUrl sources, String url, DateTime now) {
    _failed.remove(_key(scope, sources, url));
    _failed.remove('$scope|dns|${_endpoint(url)}');
    _working.remove(scope);
    _working[scope] = (_key(scope, sources, url), now);
    _prune(now);
  }

  bool _blocked(String scope, LivePlayUrl sources, String url) =>
      _failed.containsKey(_key(scope, sources, url)) ||
      _failed.containsKey('$scope|dns|${_endpoint(url)}');

  List<int> available(String scope, LivePlayUrl sources, DateTime now) {
    _prune(now);
    return [
      for (var i = 0; i < sources.urls.length; i++)
        if (!_blocked(scope, sources, sources.urls[i])) i,
    ];
  }

  int select(
    String scope,
    LivePlayUrl sources,
    String? preferred,
    DateTime now,
  ) {
    final usable = available(scope, sources, now);
    final requested = sources.indexForIdentity(preferred);
    // An only available line can still be retried with a fresh signed URL.
    if (usable.isEmpty) return requested;
    if (preferred != null &&
        sources.identityForUrl(sources.urls[requested]) == preferred &&
        usable.contains(requested)) {
      return requested;
    }
    final previous = _working[scope]?.$1;
    for (final index in usable) {
      if (_key(scope, sources, sources.urls[index]) == previous) return index;
    }
    return usable.first;
  }
}
