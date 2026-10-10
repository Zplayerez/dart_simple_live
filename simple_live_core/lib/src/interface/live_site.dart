import '../account/platform_account.dart';
import 'package:simple_live_core/src/model/live_anchor_item.dart';

import '../interface/live_danmaku.dart';
import '../model/live_category_result.dart';
import '../model/live_message.dart';
import '../model/live_play_url.dart';
import '../model/live_room_detail.dart';
import '../model/live_search_result.dart';

import '../model/live_category.dart';
import '../model/live_play_quality.dart';
import '../model/live_room_item.dart';

class LiveSite {
  LiveSite({this.id = "", this.name = ""});
  LiveAccountSession? _accountSession;
  LiveAccountSession? get accountSession => _accountSession;
  set accountSession(LiveAccountSession? value) {
    if (value != null && value.platform.name != id) {
      throw ArgumentError('Account platform does not match site');
    }
    _accountSession = value;
    onAccountSessionChanged();
  }

  /// Accepted same-revision server rotation. This does not request playback restart.
  void Function(LiveAccountSession updated)? onAccountSessionUpdated;

  AccountRequestHeaders accountRequestHeaders(
    LiveAccountSession? snapshot,
    Map<String, String> headers,
  ) {
    return AccountRequestHeaders(headers, (uri, cookies) {
      final current = _accountSession;
      if (snapshot == null ||
          current == null ||
          snapshot.version != current.version ||
          !current.permits(uri)) {
        return;
      }
      // A delayed response may only rotate keys still matching its request.
      // Independent keys from concurrent responses can still be merged.
      final eligible = cookies.where((header) {
        try {
          final keys = PlatformCookie.parse(
            header.split(';').first,
          ).values.keys;
          return keys.every(
            (key) => snapshot.cookie.values[key] == current.cookie.values[key],
          );
        } on FormatException {
          return false;
        }
      });
      final updatedCookie = current.cookie.mergeResponseCookies(uri, eligible);
      if (updatedCookie.header == current.cookie.header) return;
      final updated = LiveAccountSession(
        platform: current.platform,
        cookie: updatedCookie,
        version: current.version,
      );
      _accountSession = updated;
      onAccountSessionUpdated?.call(updated);
    });
  }

  /// Provider caches must be cleared synchronously on login/logout/switch.
  void onAccountSessionChanged() {}

  /// 站点唯一ID
  String id;

  /// 站点名称
  String name;

  /// 站点名称
  LiveDanmaku getDanmaku() => LiveDanmaku();

  /// 读取网站的分类
  Future<List<LiveCategory>> getCategores() {
    return Future.value(<LiveCategory>[]);
  }

  /// 搜索直播间
  Future<LiveSearchRoomResult> searchRooms(String keyword, {int page = 1}) {
    return Future.value(
      LiveSearchRoomResult(hasMore: false, items: <LiveRoomItem>[]),
    );
  }

  /// 搜索直播间
  Future<LiveSearchAnchorResult> searchAnchors(String keyword, {int page = 1}) {
    return Future.value(
      LiveSearchAnchorResult(hasMore: false, items: <LiveAnchorItem>[]),
    );
  }

  /// 读取类目下房间
  Future<LiveCategoryResult> getCategoryRooms(
    LiveSubCategory category, {
    int page = 1,
  }) {
    return Future.value(
      LiveCategoryResult(hasMore: false, items: <LiveRoomItem>[]),
    );
  }

  /// 读取推荐的房间
  Future<LiveCategoryResult> getRecommendRooms({int page = 1}) {
    return Future.value(
      LiveCategoryResult(hasMore: false, items: <LiveRoomItem>[]),
    );
  }

  /// 读取房间详情
  Future<LiveRoomDetail> getRoomDetail({required String roomId}) {
    return Future.value(
      LiveRoomDetail(
        cover: '',
        online: 0,
        roomId: '',
        status: false,
        title: '',
        url: '',
        userAvatar: '',
        userName: '',
      ),
    );
  }

  /// 读取房间清晰度
  Future<List<LivePlayQuality>> getPlayQualites({
    required LiveRoomDetail detail,
  }) {
    return Future.value(<LivePlayQuality>[]);
  }

  /// 读取播放链接
  Future<LivePlayUrl> getPlayUrls({
    required LiveRoomDetail detail,
    required LivePlayQuality quality,
  }) {
    return Future.value(LivePlayUrl(urls: []));
  }

  /// 查询直播状态
  Future<bool> getLiveStatus({required String roomId}) {
    return Future.value(false);
  }

  /// 读取指定房间的SC
  Future<List<LiveSuperChatMessage>> getSuperChatMessage({
    required String roomId,
  }) {
    return Future.value([]);
  }
}
