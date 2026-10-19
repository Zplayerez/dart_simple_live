import '../interface/live_site.dart';
import '../douyu_site.dart';
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
    List<LivePlayQuality>? previousQualities,
  }) async {
    final detail = await site.getRoomDetail(roomId: roomId);
    if (!detail.status && !detail.isRecord) return null;
    List<LivePlayQuality> qualities;
    try {
      qualities = await site.getPlayQualites(detail: detail);
    } on DouyuPlayException catch (error) {
      // A failed auto-CDN quality discovery must not prevent trying the known
      // rate/CDNs with a fresh room signature. Never reuse an old signed URL.
      if (site is! DouyuSite ||
          error.code != -5 ||
          selected.data is! DouyuPlayData ||
          previousQualities == null ||
          previousQualities.isEmpty) {
        rethrow;
      }
      qualities = List.of(previousQualities);
    }
    if (qualities.isEmpty) throw StateError('暂时无法获取清晰度');
    // Douyu can rename 原画 to 原画1080P60 while rate=0 remains unchanged.
    // Match its stable rate and use the fresh quality/CDNs, never the old URL.
    final selectedData = selected.data;
    var index = qualities.indexWhere((quality) {
      final data = quality.data;
      if (site is DouyuSite && selectedData is DouyuPlayData) {
        return data is DouyuPlayData && data.rate == selectedData.rate;
      }
      return quality.quality == selected.quality;
    });
    if (!allowQualityFallback && index < 0) {
      throw StateError('所选画质暂时不可用，请重新选择画质');
    }
    if (index < 0) index = 0;
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
