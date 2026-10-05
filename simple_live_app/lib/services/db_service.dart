import 'package:get/get.dart';
import 'package:hive/hive.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/models/db/follow_user_tag.dart';
import 'package:simple_live_app/models/db/history.dart';
import 'package:uuid/uuid.dart';
import 'package:collection/collection.dart';

class DBService extends GetxService {
  static DBService get instance => Get.find<DBService>();
  late Box<History> historyBox;
  late Box<FollowUser> followBox;
  late Box<FollowUserTag> tagBox;
  final Uuid uuid = const Uuid();

  Future<void> init() async {
    await Future.wait([
      Hive.openBox<History>("History").then((box) => historyBox = box),
      Hive.openBox<FollowUser>("FollowUser").then((box) => followBox = box),
      Hive.openBox<FollowUserTag>("FollowUserTag").then((box) => tagBox = box),
    ]);
    await _repairFollowTags();
  }

  /// Repair older releases that stored reordered tags under numeric Hive keys.
  /// Write canonical records before removing aliases, retaining memberships.
  Future<void> _repairFollowTags() async {
    final entries = {for (final key in tagBox.keys) key: tagBox.get(key)!};
    final byName = <String, FollowUserTag>{};
    for (final tag in entries.values) {
      final existing = byName[tag.tag];
      if (existing == null) {
        byName[tag.tag] = tag;
      } else {
        existing.userId = {...existing.userId, ...tag.userId}.toList();
      }
    }
    final canonical = {for (final tag in byName.values) tag.id: tag};
    if (entries.entries.any((entry) => entry.key != entry.value.id) ||
        canonical.length != entries.length) {
      await tagBox.putAll(canonical);
      await tagBox
          .deleteAll(entries.keys.where((key) => !canonical.containsKey(key)));
    }
  }

  // follow_user_tag 相关逻辑
  bool getFollowTagExist(String id) {
    return tagBox.containsKey(id);
  }

  // 删除标签
  Future deleteFollowTag(String id) async {
    await tagBox.delete(id);
  }

  FollowUserTag? getFollowTag(String tag) {
    return tagBox.values.firstWhereOrNull((item) => item.tag == tag);
  }

  // 判断标签名称是否重复
  bool getFollowTagExistByTag(String tag) {
    return tagBox.values.any((item) => item.tag == tag);
  }

  // 获取标签列表
  List<FollowUserTag> getFollowTagList() {
    final tags = tagBox.values.toList();
    // Stable tie order keeps old records (without an order field) unchanged.
    return tags.sortedBy<num>((tag) => tag.order);
  }

  // 修改标签
  Future updateFollowTag(FollowUserTag followTag) async {
    await tagBox.put(followTag.id, followTag);
  }

  // 添加标签
  Future<FollowUserTag> addFollowTag(String tag) async {
    tag = tag.trim();
    if (tag.isEmpty) throw const FormatException('标签名称不能为空');
    if (getFollowTagExistByTag(tag)) {
      return getFollowTag(tag)!;
    }
    final String uniqueId = uuid.v4();
    final order =
        tagBox.values.fold<int>(-1, (n, tag) => tag.order > n ? tag.order : n) +
            1;
    final followUserTag =
        FollowUserTag(id: uniqueId, tag: tag, userId: [], order: order);
    await tagBox.put(uniqueId, followUserTag);
    return followUserTag;
  }

  // 调整标签顺序
  Future updateFollowTagOrder(List<FollowUserTag> userTagList) async {
    final updatedMap = <String, FollowUserTag>{};
    for (var i = 0; i < userTagList.length; i++) {
      final tag = userTagList[i];
      tag.order = i;
      updatedMap[tag.id] = tag;
    }
    await tagBox.putAll(updatedMap);
  }

  bool getFollowExist(String id) {
    return followBox.containsKey(id);
  }

  List<FollowUser> getFollowList() {
    return followBox.values.toList();
  }

  Future addFollow(FollowUser follow) async {
    await followBox.put(follow.id, follow);
  }

  Future deleteFollow(String id) async {
    await followBox.delete(id);
  }

  History? getHistory(String id) {
    if (historyBox.containsKey(id)) {
      return historyBox.get(id);
    }
    return null;
  }

  Future addOrUpdateHistory(History history) async {
    await historyBox.put(history.id, history);
  }

  List<History> getHistores() {
    var his = historyBox.values.toList();
    his.sort((a, b) => b.updateTime.compareTo(a.updateTime));
    return his;
  }
}
