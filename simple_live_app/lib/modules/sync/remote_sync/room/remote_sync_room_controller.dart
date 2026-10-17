import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/controller/base_controller.dart';
import 'package:simple_live_app/app/event_bus.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/models/db/history.dart';
import 'package:simple_live_app/services/db_service.dart';
import 'package:simple_live_app/services/signalr_service.dart';

class RemoteSyncRoomController extends BaseController {
  final String roomId;
  final SignalRService signalR;
  RemoteSyncRoomController(this.roomId, {SignalRService? service})
      : signalR = service ?? SignalRService() {
    if (roomId.isNotEmpty) {
      currentRoomId.value = roomId;
    }
  }
  StreamSubscription? _roomDestroyedSubscription;
  StreamSubscription? _roomUserUpdatedSubscription;
  StreamSubscription? _onFavoriteSubscription;
  StreamSubscription? _onHistorySubscription;
  StreamSubscription? _onShieldWordSubscription;
  StreamSubscription? _onBiliAccountSubscription;
  var currentRoomId = "--".obs;
  RxList<RoomUser> roomUsers = <RoomUser>[].obs;

  final busy = false.obs;
  final errorMessage = ''.obs;
  final ready = false.obs;
  bool _closed = false;
  StreamSubscription? _stateSubscription;
  Timer? _timer;
  var countDown = 600.obs;

  @override
  void onInit() {
    listenSignalR();
    connect();
    super.onInit();
  }

  Future<void> connect() async {
    if (_closed || busy.value) return;
    busy.value = true;
    ready.value = false;
    errorMessage.value = '';
    roomUsers.clear();
    _timer?.cancel();
    try {
      await signalR.connect();
      if (_closed) return;
      if (roomId.isEmpty) {
        final resp = await signalR.createRoom();
        if (_closed) return;
        if (!resp.isSuccess) throw RemoteSyncException(resp.message);
        currentRoomId.value = resp.data!;
        _startTimer();
      } else {
        final resp = await signalR.joinRoom(roomId);
        if (_closed) return;
        if (!resp.isSuccess) throw RemoteSyncException(resp.message);
      }
      ready.value = true;
    } catch (error) {
      if (_closed) return;
      errorMessage.value =
          RemoteSyncException.fromError(error, roomId.isEmpty ? '创建房间' : '加入房间')
              .message;
      Log.w(
          'RemoteSync room setup failed: ${error.runtimeType}; ${errorMessage.value}');
      await signalR.disconnect();
    } finally {
      if (!_closed) busy.value = false;
    }
  }

  void _startTimer() {
    // 房间有效期10分钟；重试前取消旧计时器。
    _timer?.cancel();
    countDown.value = 600;
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      countDown--;
      if (countDown <= 0) {
        timer.cancel();
        Get.back();
      }
    });
  }

  void listenSignalR() {
    _stateSubscription = signalR.stateStream.listen((state) {
      if (_closed ||
          busy.value ||
          !ready.value ||
          state != SignalRConnectionState.disconnected) {
        return;
      }
      ready.value = false;
      roomUsers.clear();
      _timer?.cancel();
      errorMessage.value = '连接已断开，请重新连接同步房间';
    });
    _roomDestroyedSubscription = signalR.onRoomDestroyedStream.listen((roomId) {
      ready.value = false;
      _timer?.cancel();
      roomUsers.clear();
      errorMessage.value = '房间已关闭，请重新创建或加入房间';
    });
    _roomUserUpdatedSubscription = signalR.onRoomUserUpdatedStream.listen(
      (roomUsers) {
        this.roomUsers.assignAll(roomUsers);
      },
    );
    _onFavoriteSubscription = signalR.onFavoriteStream.listen((data) {
      onReceiveFavorite(data.$1, data.$2);
    });
    _onHistorySubscription = signalR.onHistoryStream.listen((data) {
      onReceiveHistory(data.$1, data.$2);
    });
    _onShieldWordSubscription = signalR.onShieldWordStream.listen((data) {
      onReceiveShieldWord(data.$1, data.$2);
    });
    _onBiliAccountSubscription = signalR.onBiliAccountStream.listen((data) {
      onReceiveBiliAccount(data.$1, data.$2);
    });
  }

  void onReceiveFavorite(bool overlay, String data) async {
    try {
      var jsonBody = json.decode(data);
      if (overlay) {
        await DBService.instance.followBox.clear();
      }
      for (var item in jsonBody) {
        var user = FollowUser.fromJson(item);
        await DBService.instance.followBox.put(user.id, user);
      }
      SmartDialog.showToast('已同步关注用户列表');
      EventBus.instance.emit(Constant.kUpdateFollow, 0);
      SmartDialog.showToast("已同步关注列表");
    } catch (e) {
      SmartDialog.showToast("同步失败:$e");
      Log.logPrint(e);
    }
  }

  void onReceiveHistory(bool overlay, String data) async {
    try {
      var jsonBody = json.decode(data);
      if (overlay) {
        await DBService.instance.historyBox.clear();
      }
      for (var item in jsonBody) {
        var history = History.fromJson(item);
        if (DBService.instance.historyBox.containsKey(history.id)) {
          var old = DBService.instance.historyBox.get(history.id);
          //如果本地的更新时间比较新，就不更新
          if (old!.updateTime.isAfter(history.updateTime)) {
            continue;
          }
        }
        await DBService.instance.addOrUpdateHistory(history);
      }
      SmartDialog.showToast('已同步历史记录');
      EventBus.instance.emit(Constant.kUpdateHistory, 0);
    } catch (e) {
      SmartDialog.showToast("同步失败:$e");
      Log.logPrint(e);
    }
  }

  void onReceiveShieldWord(bool overlay, String data) async {
    try {
      var jsonBody = json.decode(data);
      if (overlay) {
        AppSettingsController.instance.clearShieldList();
      }
      for (var item in jsonBody) {
        // add to Hive
        AppSettingsController.instance.addShieldList(item);
      }
      SmartDialog.showToast('已同步屏蔽词');
    } catch (e) {
      SmartDialog.showToast("同步失败:$e");
      Log.logPrint(e);
    }
  }

  void onReceiveBiliAccount(bool overlay, String data) {
    SmartDialog.showToast('请在账号管理中使用加密配对接收账号');
  }

  Future<bool> showOverlayDialog() async {
    var overlay = await Utils.showAlertDialog(
      "是否覆盖远端数据？",
      title: "数据覆盖",
      confirm: "覆盖",
      cancel: "不覆盖",
    );
    return overlay;
  }

  void syncFollow() async {
    try {
      if (roomUsers.length <= 1) {
        SmartDialog.showToast("无设备连接");
        return;
      }

      var overlay = await showOverlayDialog();
      SmartDialog.showLoading(msg: "发送中...");
      var users = DBService.instance.getFollowList();
      var data = json.encode(users.map((e) => e.toJson()).toList());

      var resp = await signalR.sendContent(
        roomName: currentRoomId.value,
        action: "SendFavorite",
        overlay: overlay,
        content: data,
      );
      if (resp.isSuccess) {
        SmartDialog.showToast("已发送关注列表");
      } else {
        SmartDialog.showToast("发送失败:${resp.message}");
      }
    } catch (e) {
      SmartDialog.showToast("发送失败:$e");
      Log.logPrint(e);
    } finally {
      SmartDialog.dismiss();
    }
  }

  void syncHistory() async {
    try {
      if (roomUsers.length <= 1) {
        SmartDialog.showToast("无设备连接");
        return;
      }
      var overlay = await showOverlayDialog();
      SmartDialog.showLoading(msg: "发送中...");
      var histores = DBService.instance.getHistores();
      var data = json.encode(histores.map((e) => e.toJson()).toList());
      var resp = await signalR.sendContent(
        roomName: currentRoomId.value,
        action: "SendHistory",
        overlay: overlay,
        content: data,
      );
      if (resp.isSuccess) {
        SmartDialog.showToast("已发送历史记录");
      } else {
        SmartDialog.showToast("发送失败:${resp.message}");
      }
    } catch (e) {
      SmartDialog.showToast("发送失败:$e");
      Log.logPrint(e);
    } finally {
      SmartDialog.dismiss();
    }
  }

  void syncBlockedWord() async {
    try {
      if (roomUsers.length <= 1) {
        SmartDialog.showToast("无设备连接");
        return;
      }
      var overlay = await showOverlayDialog();
      SmartDialog.showLoading(msg: "发送中...");
      var shieldList = AppSettingsController.instance.shieldList;
      var data = json.encode(shieldList.toList());

      var resp = await signalR.sendContent(
        roomName: currentRoomId.value,
        action: "SendShieldWord",
        overlay: overlay,
        content: data,
      );
      if (resp.isSuccess) {
        SmartDialog.showToast("已发送屏蔽词");
      } else {
        SmartDialog.showToast("发送失败:${resp.message}");
      }
    } catch (e) {
      SmartDialog.showToast("发送失败:$e");
      Log.logPrint(e);
    } finally {
      SmartDialog.dismiss();
    }
  }

  void syncBiliAccount() {
    SmartDialog.showToast('请在账号管理中使用加密配对发送账号');
  }

  void showQRInfo() {
    Utils.showBottomSheet(
      title: "房间信息",
      child: Column(
        children: [
          QrImageView(
            data: currentRoomId.value,
            version: QrVersions.auto,
            backgroundColor: Colors.white,
            padding: AppStyle.edgeInsetsA12,
            size: 200,
          ),
          AppStyle.vGap24,
          Text(
            currentRoomId.value,
            textAlign: TextAlign.center,
            style: Get.textTheme.titleLarge,
          ),
          const Text(
            "请使用其他Simple Live客户端扫描上方二维码\n建立连接后可选择需要同步的数据",
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  @override
  void onClose() {
    _closed = true;
    _timer?.cancel();
    _stateSubscription?.cancel();
    _roomDestroyedSubscription?.cancel();
    _roomUserUpdatedSubscription?.cancel();
    _onFavoriteSubscription?.cancel();
    _onHistorySubscription?.cancel();
    _onShieldWordSubscription?.cancel();
    _onBiliAccountSubscription?.cancel();
    signalR.dispose();
    super.onClose();
  }
}
