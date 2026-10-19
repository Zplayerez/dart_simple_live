import 'dart:async';
import 'dart:convert';

import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:simple_live_tv_app/app/constant.dart';
import 'package:simple_live_tv_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_tv_app/app/controller/base_controller.dart';
import 'package:simple_live_tv_app/app/event_bus.dart';
import 'package:simple_live_tv_app/app/log.dart';
import 'package:simple_live_tv_app/models/db/follow_user.dart';
import 'package:simple_live_tv_app/models/db/history.dart';
import 'package:simple_live_tv_app/services/db_service.dart';
import 'package:simple_live_tv_app/services/signalr_service.dart';
import 'package:simple_live_tv_app/services/sync_service.dart';

class SyncController extends BaseController {
  SyncController({SignalRService? remoteService})
      : signalR = remoteService ?? SignalRService();
  final SignalRService signalR;
  StreamSubscription? _stateSubscription;
  StreamSubscription? _roomDestroyedSubscription;
  StreamSubscription? _roomUserUpdatedSubscription;
  StreamSubscription? _onFavoriteSubscription;
  StreamSubscription? _onHistorySubscription;
  StreamSubscription? _onShieldWordSubscription;
  StreamSubscription? _onBiliAccountSubscription;
  var currentRoomId = "--".obs;
  RxList<RoomUser> roomUsers = <RoomUser>[].obs;
  Timer? _timer;
  final busy = false.obs;
  final ready = false.obs;
  final errorMessage = ''.obs;
  bool _closed = false;
  var countDown = 600.obs;

  Rx<SignalRConnectionState> state =
      Rx<SignalRConnectionState>(SignalRConnectionState.disconnected);

  @override
  void onInit() {
    SyncService.instance.initServer();
    SyncService.instance.listenUDP();
    listenSignalR();
    super.onInit();
  }

  Future<void> refreshLocalConnection() async {
    await SyncService.instance.initServer();
    await SyncService.instance.listenUDP();
    await SyncService.instance.sendInfo();
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
      final resp = await signalR.createRoom();
      if (_closed) return;
      if (!resp.isSuccess) throw RemoteSyncException(resp.message);
      currentRoomId.value = resp.data!;
      ready.value = true;
      _startTimer();
    } catch (error) {
      if (_closed) return;
      errorMessage.value = RemoteSyncException.fromError(error, '创建房间').message;
      Log.w(
          'RemoteSync room setup failed: ${error.runtimeType}; ${errorMessage.value}');
      await signalR.disconnect();
    } finally {
      if (!_closed) busy.value = false;
    }
  }

  void _startTimer() {
    // 房间有效期10分钟。
    _timer?.cancel();
    countDown.value = 600;
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      countDown--;
      if (countDown <= 0) {
        timer.cancel();
        ready.value = false;
        errorMessage.value = '远程房间已到期，可以重新创建';
        signalR.disconnect();
      }
    });
  }

  void listenSignalR() {
    _stateSubscription = signalR.stateStream.listen((event) {
      state.value = event;
      if (!_closed &&
          !busy.value &&
          event == SignalRConnectionState.disconnected &&
          ready.value) {
        ready.value = false;
        _timer?.cancel();
        errorMessage.value = '连接已断开，请重试；局域网同步仍可使用';
      }
    });
    _roomDestroyedSubscription = signalR.onRoomDestroyedStream.listen((roomId) {
      ready.value = false;
      _timer?.cancel();
      errorMessage.value = '远程房间已关闭，可以重新创建；局域网同步仍可使用';
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
