import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:path_provider/path_provider.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/event_bus.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/models/db/follow_user_tag.dart';
import 'package:simple_live_app/services/db_service.dart';
import 'package:simple_live_app/services/local_storage_service.dart';

class FollowService extends GetxService {
  StreamSubscription<dynamic>? subscription;
  static FollowService get instance => Get.find<FollowService>();

  final StreamController _updatedListController = StreamController.broadcast();
  Stream get updatedListStream => _updatedListController.stream;

  /// 关注用户列表
  RxList<FollowUser> followList = RxList<FollowUser>();

  /// 直播中的用户列表
  RxList<FollowUser> liveList = RxList<FollowUser>();

  /// 未直播的用户列表
  RxList<FollowUser> notLiveList = RxList<FollowUser>();

  /// 用户自定义的tag
  RxList<FollowUserTag> followTagList = RxList<FollowUserTag>();

  /// 当前tag的用户列表
  RxList<FollowUser> curTagFollowList = RxList<FollowUser>();

  /// 已经更新状态的数量
  var updatedCount = 0;
  Future<void>? _statusUpdate;
  final pinnedIds = <String>{}.obs;

  Future<void> togglePin(FollowUser item) async {
    if (!pinnedIds.remove(item.id)) pinnedIds.add(item.id);
    await LocalStorageService.instance
        .setValue('PinnedFollows', pinnedIds.toList());
    _orderPinnedFirst();
    filterData();
  }

  void _orderPinnedFirst() {
    final pinned =
        followList.where((item) => pinnedIds.contains(item.id)).toList();
    final others =
        followList.where((item) => !pinnedIds.contains(item.id)).toList();
    followList.assignAll([...pinned, ...others]);
  }

  /// 是否正在更新
  var updating = false.obs;

  Timer? updateTimer;

  @override
  void onInit() {
    subscription = EventBus.instance.listen(Constant.kUpdateFollow, (p0) {
      loadData(updateStatus: false);
    });
    pinnedIds.addAll(LocalStorageService.instance
        .getValue<List>('PinnedFollows', []).whereType<String>());
    initTimer();
    super.onInit();
  }

  // 添加标签
  Future<void> addFollowUserTag(String tag) async {
    // 判断待添加tag是否已存在，存在则return
    if (followTagList.any((item) => item.tag == tag)) {
      SmartDialog.showToast("标签名重复，修改失败");
      return;
    }
    FollowUserTag item = await DBService.instance.addFollowTag(tag);
    followTagList.add(item);
  }

  // 删除标签
  Future<void> delFollowUserTag(FollowUserTag tag) async {
    followTagList.remove(tag);
    await DBService.instance.deleteFollowTag(tag.id);
  }

  // 获取用户自定义标签列表
  void getAllTagList() {
    var list = DBService.instance.getFollowTagList();
    followTagList.assignAll(list);
  }

  // 修改标签
  void updateFollowUserTag(FollowUserTag tag) {
    DBService.instance.updateFollowTag(tag);
    // 查找并修改
    var index = followTagList.indexWhere((oTag) => oTag.id == tag.id);
    if (index >= 0) followTagList[index] = tag;
  }

  // 根据标签筛选数据
  void filterDataByTag(FollowUserTag tag) {
    curTagFollowList.clear();
    // 用一个新的列表来存储需要删除的 userId
    List<String> toRemove = [];
    for (var id in tag.userId) {
      if (followList.any((x) => x.id == id)) {
        // 找到对应的 followUser 添加到 curTagFollowList
        curTagFollowList.add(followList.firstWhere((x) => x.id == id));
      } else {
        // 标记要删除的 id
        toRemove.add(id);
      }
    }
    // 双向确认用户取消关注后标签内是否还有该用户
    // 在遍历结束后统一移除不在 followList 中的 id
    tag.userId.removeWhere((id) => toRemove.contains(id));
    // 更新数据库
    if (toRemove.isNotEmpty) {
      DBService.instance.updateFollowTag(tag);
    }
    // Preserve the same order as the main list while status changes.
    curTagFollowList
        .assignAll(followList.where((item) => tag.userId.contains(item.id)));
  }

  // 添加关注
  Future<void> addFollow(FollowUser follow) async {
    await DBService.instance.addFollow(follow);
  }

  void initTimer() {
    if (AppSettingsController.instance.autoUpdateFollowEnable.value) {
      updateTimer?.cancel();
      updateTimer = Timer.periodic(
        Duration(
            minutes:
                AppSettingsController.instance.autoUpdateFollowDuration.value),
        (timer) {
          Log.logPrint("Update Follow Timer");
          loadData();
        },
      );
    } else {
      updateTimer?.cancel();
    }
  }

  Future<void> loadData({bool updateStatus = true}) async {
    final existing = {for (final item in followList) item.id: item};
    final stored = DBService.instance.getFollowList();
    final refreshed = stored.map((item) {
      final previous = existing[item.id];
      if (previous != null && !identical(previous, item)) {
        item.liveStatus.value = previous.liveStatus.value;
        item.liveStartTime = previous.liveStartTime;
        item.checkedAt = previous.checkedAt;
      }
      return item;
    }).toList();
    // Retain visible order; newly followed rooms are appended.
    final byId = {for (final item in refreshed) item.id: item};
    followList.assignAll([
      for (final id in existing.keys)
        if (byId.containsKey(id)) byId.remove(id)!,
      ...byId.values,
    ]);
    getAllTagList();
    _orderPinnedFirst();
    filterData();
    if (updateStatus) await startUpdateStatus();
  }

  /// 获取最优并发数
  /// 根据 CPU 核心数和用户设置自动计算
  int getOptimalConcurrency() {
    var userSetting =
        AppSettingsController.instance.updateFollowThreadCount.value;

    // 如果用户设置为 0，则自动根据 CPU 核心数计算
    if (userSetting == 0) {
      var cpuCount = Platform.numberOfProcessors;
      // 网络 I/O 密集型任务，并发数可以是 CPU 核心数的 2-3 倍
      var optimal = (cpuCount * 2.5).round();
      // 限制在合理范围内（最少 4，最多 20）
      return optimal.clamp(4, 20);
    }

    return userSetting;
  }

  /// 按平台交错排列，避免单一平台阻塞
  List<FollowUser> interleaveByPlatform(List<FollowUser> list) {
    // 按平台分组
    var grouped = <String, Queue<FollowUser>>{};
    for (var item in list) {
      grouped.putIfAbsent(item.siteId, () => Queue<FollowUser>()).add(item);
    }

    // 交错处理
    var result = <FollowUser>[];
    while (grouped.values.any((queue) => queue.isNotEmpty)) {
      for (var queue in grouped.values) {
        if (queue.isNotEmpty) {
          result.add(queue.removeFirst());
        }
      }
    }

    return result;
  }

  Future<void> startUpdateStatus({bool failuresOnly = false}) {
    final pending = _statusUpdate;
    if (pending != null) return pending;
    final candidates = followList
        .where((item) => !failuresOnly || item.liveStatus.value == -1)
        .toList();
    if (candidates.isEmpty) return Future.value();
    final completion = Completer<void>();
    _statusUpdate = completion.future;
    _updateStatuses(candidates).then((_) {
      _statusUpdate = null;
      completion.complete();
    }, onError: (Object error, StackTrace stack) {
      _statusUpdate = null;
      completion.completeError(error, stack);
    });
    return completion.future;
  }

  Future<void> _updateStatuses(List<FollowUser> candidates) async {
    updatedCount = 0;
    updating.value = true;
    final queue = Queue<FollowUser>.from(interleaveByPlatform(candidates));
    Future<void> worker() async {
      while (queue.isNotEmpty && !isClosed) {
        await updateLiveStatus(queue.removeFirst());
        updatedCount++;
      }
    }

    try {
      await Future.wait(
          List.generate(getOptimalConcurrency().clamp(1, 20), (_) => worker()));
    } finally {
      if (!isClosed) {
        updating.value = false;
        filterData();
      }
    }
  }

  Future<void> updateLiveStatus(FollowUser item) async {
    item.checking.value = true;
    try {
      final site = Sites.allSites[item.siteId]!;
      bool current() =>
          !isClosed && followList.any((entry) => identical(entry, item));
      if (item.siteId == Constant.kDouyin) {
        // Douyin's status endpoint already fetches the full room information.
        final detail = await site.liveSite
            .getRoomDetail(roomId: item.roomId)
            .timeout(const Duration(seconds: 15));
        if (!current()) return;
        item.liveStatus.value = detail.status ? 2 : 1;
        item.liveStartTime = detail.status ? detail.showTime : null;
      } else {
        // Keep lightweight status queries for other platforms and offline rooms.
        final live = await site.liveSite
            .getLiveStatus(roomId: item.roomId)
            .timeout(const Duration(seconds: 10));
        if (!current()) return;
        item.liveStatus.value = live ? 2 : 1;
        item.liveStartTime = null;
        filterData();
        if (live) {
          try {
            final detail = await site.liveSite
                .getRoomDetail(roomId: item.roomId)
                .timeout(const Duration(seconds: 10));
            if (!current()) return;
            item.liveStatus.value = detail.status ? 2 : 1;
            item.liveStartTime = detail.status ? detail.showTime : null;
          } catch (_) {
            // Missing supplementary details do not invalidate confirmed status.
          }
        }
      }
    } catch (_) {
      if (!isClosed) item.liveStatus.value = -1;
    } finally {
      if (!isClosed) {
        item.checkedAt = DateTime.now();
        item.checking.value = false;
        filterData();
      }
    }
  }

  void filterData() {
    liveList.assignAll(followList.where((x) => x.liveStatus.value == 2));
    notLiveList.assignAll(followList.where((x) => x.liveStatus.value == 1));
    if (!_updatedListController.isClosed) _updatedListController.add(0);
  }

  void exportFile() async {
    if (followList.isEmpty) {
      SmartDialog.showToast("列表为空");
      return;
    }

    try {
      var status = await Utils.checkStorgePermission();
      if (!status) {
        SmartDialog.showToast("无权限");
        return;
      }

      var dir = "";
      if (Platform.isIOS) {
        dir = (await getApplicationDocumentsDirectory()).path;
      } else {
        dir = await FilePicker.platform.getDirectoryPath() ?? "";
      }

      if (dir.isEmpty) {
        return;
      }
      var jsonFile = File(
          '$dir/SimpleLive_${DateTime.now().millisecondsSinceEpoch ~/ 1000}.json');
      var jsonText = generateJson();
      await jsonFile.writeAsString(jsonText);
      SmartDialog.showToast("已导出关注列表");
    } catch (e) {
      Log.logPrint(e);
      SmartDialog.showToast("导出失败：$e");
    }
  }

  void inputFile() async {
    try {
      var status = await Utils.checkStorgePermission();
      if (!status) {
        SmartDialog.showToast("无权限");
        return;
      }
      var file = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json'],
      );
      if (file == null) {
        return;
      }
      var jsonFile = File(file.files.single.path!);
      await inputJson(await jsonFile.readAsString());
      SmartDialog.showToast("导入成功");
    } catch (e) {
      Log.logPrint(e);
      SmartDialog.showToast("导入失败:$e");
    } finally {
      loadData();
    }
  }

  void exportText() {
    if (followList.isEmpty) {
      SmartDialog.showToast("列表为空");
      return;
    }
    var content = generateJson();
    Get.dialog(
      AlertDialog(
        title: const Text("导出为文本"),
        content: TextField(
          controller: TextEditingController(text: content),
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
          ),
          minLines: 5,
          maxLines: 8,
        ),
        actions: [
          TextButton(
            onPressed: () {
              Get.back();
            },
            child: const Text("关闭"),
          ),
          TextButton(
            onPressed: () {
              Utils.copyToClipboard(content);
              Get.back();
            },
            child: const Text("复制"),
          ),
        ],
      ),
    );
  }

  void inputText() async {
    final TextEditingController textController = TextEditingController();
    await Get.dialog(
      AlertDialog(
        title: const Text("从文本导入"),
        content: TextField(
          controller: textController,
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            hintText: "请输入内容",
          ),
          minLines: 5,
          maxLines: 8,
        ),
        actions: [
          TextButton(
            onPressed: () {
              Get.back();
            },
            child: const Text("关闭"),
          ),
          TextButton(
            onPressed: () async {
              var content = await Utils.getClipboard();
              if (content != null) {
                textController.text = content;
              }
            },
            child: const Text("粘贴"),
          ),
          TextButton(
            onPressed: () async {
              if (textController.text.isEmpty) {
                SmartDialog.showToast("内容为空");
                return;
              }
              try {
                await inputJson(textController.text);
                SmartDialog.showToast("导入成功");
                Get.back();
                loadData();
              } catch (e) {
                SmartDialog.showToast("导入失败，请检查内容是否正确");
              }
            },
            child: const Text("导入"),
          ),
        ],
      ),
    );
  }

  String generateJson() {
    var data = followList
        .map(
          (item) => {
            "siteId": item.siteId,
            "id": item.id,
            "roomId": item.roomId,
            "userName": item.userName,
            "face": item.face,
            "addTime": item.addTime.toString(),
            "tag": item.tag
          },
        )
        .toList();
    return jsonEncode(data);
  }

  Future inputJson(String content) async {
    var data = jsonDecode(content);

    for (var item in data) {
      var follow = FollowUser.fromJson(item);
      // 导入关注列表同时导入标签列表 此方法可优化为所有导入逻辑
      if (follow.tag != "全部") {
        // logic: 尝试添加，存在则返回已存在的对象
        var tag = await DBService.instance.addFollowTag(follow.tag);
        // 更新tag
        tag.userId.addIf(!tag.userId.contains(follow.id), follow.id);
        await DBService.instance.updateFollowTag(tag);
      }
      await DBService.instance.addFollow(follow);
    }
  }

  @override
  void onClose() {
    updateTimer?.cancel();
    subscription?.cancel();
    _updatedListController.close();
    super.onClose();
  }
}
