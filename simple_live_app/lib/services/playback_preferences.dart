import 'local_storage_service.dart';

/// Non-secret preferences only; signed URLs and account data are never saved.
class PlaybackPreferences {
  static const _prefix = 'PlaybackPreference';
  static Map read(String siteId, String roomId) {
    final store = LocalStorageService.instance;
    final platform = store.getValue<Map>('$_prefix.$siteId', {});
    final room = store.getValue<Map>('$_prefix.$siteId.$roomId', {});
    return {...platform, ...room};
  }

  static Future<void> save(
      String siteId, String roomId, Map<String, Object?> changes,
      {bool forPlatform = false}) async {
    final store = LocalStorageService.instance;
    final key = forPlatform ? '$_prefix.$siteId' : '$_prefix.$siteId.$roomId';
    final previous = store.getValue<Map>(key, {});
    await store.setValue(key, {...previous, ...changes});
    // Choosing a platform default also removes this room's overrides.
    if (forPlatform) await store.removeValue('$_prefix.$siteId.$roomId');
  }
}
