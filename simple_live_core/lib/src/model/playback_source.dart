import '../interface/live_site.dart';
import 'live_play_quality.dart';
import 'live_play_url.dart';
import 'live_room_detail.dart';

/// One coherent room/quality/source snapshot. Embedded URLs (e.g. Douyin)
/// must come from the refreshed quality, never from a previous room response.
class PlaybackSource {
  final LiveRoomDetail detail;
  final List<LivePlayQuality> qualities;
  final int qualityIndex;
  final LivePlayUrl urls;

  const PlaybackSource({
    required this.detail,
    required this.qualities,
    required this.qualityIndex,
    required this.urls,
  });

  static int qualityIndexFor(
    List<LivePlayQuality> qualities,
    String? name, {
    int fallback = 0,
  }) {
    final index = qualities.indexWhere((q) => q.quality == name);
    return index >= 0 ? index : fallback.clamp(0, qualities.length - 1);
  }

  static Future<PlaybackSource?> refresh(
    LiveSite site,
    String roomId,
    LivePlayQuality selected, {
    bool allowQualityFallback = false,
  }) async {
    final detail = await site.getRoomDetail(roomId: roomId);
    if (!detail.status && !detail.isRecord) return null;
    final qualities = await site.getPlayQualites(detail: detail);
    if (qualities.isEmpty) throw StateError('暂时无法获取清晰度');
    if (!allowQualityFallback &&
        !qualities.any((q) => q.quality == selected.quality)) {
      throw StateError('所选画质暂时不可用，请重新选择画质');
    }
    final index = qualityIndexFor(qualities, selected.quality);
    final urls = await site.getPlayUrls(
      detail: detail,
      quality: qualities[index],
    );
    return PlaybackSource(
      detail: detail,
      qualities: qualities,
      qualityIndex: index,
      urls: urls,
    );
  }
}
