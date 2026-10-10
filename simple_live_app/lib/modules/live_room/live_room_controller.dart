import 'dart:async';

import 'package:simple_live_account/simple_live_account.dart';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:media_kit/media_kit.dart';
import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'package:share_plus/share_plus.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/event_bus.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/models/db/history.dart';
import 'package:simple_live_app/modules/live_room/player/player_controller.dart';
import 'package:simple_live_app/modules/settings/danmu_settings_page.dart';
import 'package:simple_live_app/services/db_service.dart';
import 'package:simple_live_app/services/playback_preferences.dart';
import 'package:simple_live_app/modules/mine/account/account_controller.dart';
import 'package:simple_live_app/services/follow_service.dart';
import 'package:simple_live_app/widgets/desktop_refresh_button.dart';
import 'package:simple_live_app/widgets/follow_user_item.dart';
import 'package:simple_live_core/simple_live_core.dart';
import 'package:url_launcher/url_launcher_string.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

class LiveRoomController extends PlayerController with WidgetsBindingObserver {
  final Site pSite;
  final String pRoomId;
  late LiveDanmaku liveDanmaku;
  LiveRoomController({
    required this.pSite,
    required this.pRoomId,
  }) {
    rxSite = pSite.obs;
    rxRoomId = pRoomId.obs;
    liveDanmaku = site.liveSite.getDanmaku();
    // 抖音应该默认是竖屏的
    if (site.id == "douyin") {
      isVertical.value = true;
    }
  }

  late Rx<Site> rxSite;
  Site get site => rxSite.value;
  late Rx<String> rxRoomId;
  String get roomId => rxRoomId.value;

  Rx<LiveRoomDetail?> detail = Rx<LiveRoomDetail?>(null);
  var online = 0.obs;
  var followed = false.obs;
  var liveStatus = false.obs;
  RxList<LiveSuperChatMessage> superChats = RxList<LiveSuperChatMessage>();

  /// 滚动控制
  final ScrollController scrollController = ScrollController();

  /// 聊天信息
  RxList<LiveMessage> messages = RxList<LiveMessage>();

  /// 清晰度数据
  RxList<LivePlayQuality> qualites = RxList<LivePlayQuality>();

  /// 当前清晰度
  var currentQuality = -1;
  var currentQualityInfo = "".obs;

  /// 线路数据
  RxList<String> playUrls = RxList<String>();

  Map<String, String>? playHeaders;

  /// Only finite-lived sources are prefetched; healthy playback is never replaced.
  Timer? _playUrlRefreshTimer;
  Timer? _healthyPlaybackTimer;
  final _playbackHealth = PlaybackHealthMonitor();
  final _recovery = PlaybackRecovery();
  String _recoveryReason = 'initial';
  LivePlayUrl? _activePlayUrl;
  PlaybackSource? _preloadedPlayUrl;
  DateTime? _preloadedAt;
  String? _preloadedContext;
  Future<PlaybackSource?>? _pendingPlayUrl;
  String? _pendingPlayContext;
  int _playGeneration = 0;
  final _playerCommands = PlaybackCommandQueue();
  bool _closing = false;
  Object? _roomLoad;
  bool get _inactive => _closing || isClosed;
  String? _openingContext;
  String? _pendingFailureContext;
  int _sourceSequence = 0;
  DateTime? _lastOpenedAt;
  Timer? _deferredFailureTimer;
  Timer? _retryDelayTimer;
  Completer<void>? _retryDelay;
  Worker? _accountWorker;
  int _knownAccountRevision = 0;

  int get _accountRevision =>
      PlatformAccountManager.instance.account(site.id).revision;
  String get _roomContext =>
      '${site.id}/$roomId/$_accountRevision/$_playGeneration';
  String get _playContext => _roomContext;

  void _watchAccount() {
    _knownAccountRevision = _accountRevision;
    _accountWorker = ever(PlatformAccountManager.instance.accounts, (_) {
      final revision = _accountRevision;
      if (_inactive) return;
      if (revision == _knownAccountRevision) {
        // Verification can explain a quality limit without reopening playback.
        _updateSourceInfo();
        return;
      }
      _knownAccountRevision = revision;
      // Verification alone does not change revision. Explicit account changes
      // invalidate signed URLs and reload this room once with the new session.
      refreshRoom();
    });
  }

  /// 当前线路
  var currentLineIndex = -1;
  var currentLineInfo = "".obs;
  final recoveryMessage = ''.obs;
  final qualityNotice = ''.obs;
  final smoothPlayback = false.obs;
  String? _preferredLine;
  String? _preferredQuality;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySubscription;

  String? get _lineIdentity =>
      currentLineIndex >= 0 && currentLineIndex < playUrls.length
          ? _activePlayUrl?.identityForUrl(playUrls[currentLineIndex])
          : null;

  void openAccount() => AccountController().openPlatform(site.id);

  Future<void> selectQuality(int index, {bool remember = true}) async {
    if (index < 0 || index >= qualites.length) return;
    final context = _playContext;
    if (remember) {
      _preferredQuality = qualites[index].quality;
      await PlaybackPreferences.save(
          site.id, roomId, {'quality': _preferredQuality});
      if (_inactive || context != _playContext) return;
      qualityNotice.value = '';
    }
    currentQuality = index;
    await getPlayUrl();
  }

  Future<void> restorePreferredQuality() async {
    if (qualites.isEmpty) return;
    final index = PlaybackSource.qualityIndexFor(qualites, _preferredQuality);
    await selectQuality(index);
  }

  /// 退出倒计时
  var countdown = 60.obs;

  Timer? autoExitTimer;

  /// 设置的自动关闭时间（分钟）
  var autoExitMinutes = 60.obs;

  ///是否延迟自动关闭
  var delayAutoExit = false.obs;

  /// 是否启用自动关闭
  var autoExitEnable = false.obs;

  /// 是否禁用自动滚动聊天栏
  /// - 当用户向上滚动聊天栏时，不再自动滚动
  var disableAutoScroll = false.obs;

  /// 是否处于后台
  var isBackground = false;

  /// 直播间加载失败
  var loadError = false.obs;
  Object? error;
  StackTrace? loadErrorTrace;

  // 开播时长状态变量
  var liveDuration = "00:00:00".obs;
  Timer? _liveDurationTimer;

  @override
  void onInit() {
    _watchAccount();
    _connectivitySubscription =
        Connectivity().onConnectivityChanged.listen((results) {
      if (results.any((result) => result != ConnectivityResult.none) &&
          errorMsg.value.isNotEmpty &&
          liveStatus.value &&
          !_inactive) {
        _recovery.reset(clearLines: false);
        unawaited(_handleMediaFailure());
      }
    });
    WidgetsBinding.instance.addObserver(this);
    if (FollowService.instance.followList.isEmpty) {
      FollowService.instance.loadData();
    }
    initAutoExit();
    showDanmakuState.value = AppSettingsController.instance.danmuEnable.value;
    followed.value = DBService.instance.getFollowExist("${site.id}_$roomId");
    loadData();

    scrollController.addListener(scrollListener);

    super.onInit();
  }

  void scrollListener() {
    if (scrollController.position.userScrollDirection ==
        ScrollDirection.forward) {
      disableAutoScroll.value = true;
    }
  }

  /// 初始化自动关闭倒计时
  void initAutoExit() {
    if (AppSettingsController.instance.autoExitEnable.value) {
      autoExitEnable.value = true;
      autoExitMinutes.value =
          AppSettingsController.instance.autoExitDuration.value;
      setAutoExit();
    } else {
      autoExitMinutes.value =
          AppSettingsController.instance.roomAutoExitDuration.value;
    }
  }

  void setAutoExit() {
    if (!autoExitEnable.value) {
      autoExitTimer?.cancel();
      return;
    }
    autoExitTimer?.cancel();
    countdown.value = autoExitMinutes.value * 60;
    autoExitTimer = Timer.periodic(const Duration(seconds: 1), (timer) async {
      countdown.value -= 1;
      if (countdown.value <= 0) {
        timer = Timer(const Duration(seconds: 10), () async {
          await WakelockPlus.disable();
          exit(0);
        });
        autoExitTimer?.cancel();
        var delay = await Utils.showAlertDialog("定时关闭已到时,是否延迟关闭?",
            title: "延迟关闭", confirm: "延迟", cancel: "关闭", selectable: true);
        if (delay) {
          timer.cancel();
          delayAutoExit.value = true;
          showAutoExitSheet();
          setAutoExit();
        } else {
          delayAutoExit.value = false;
          await WakelockPlus.disable();
          exit(0);
        }
      }
    });
  }
  // 弹窗逻辑

  void refreshRoom() {
    //messages.clear();
    superChats.clear();
    _stopPlayUrlRefreshTimer();
    liveDanmaku.stop();

    loadData();
  }

  /// 聊天栏始终滚动到底部
  void chatScrollToBottom() {
    if (scrollController.hasClients) {
      // 如果手动上拉过，就不自动滚动到底部
      if (disableAutoScroll.value) {
        return;
      }
      scrollController.jumpTo(scrollController.position.maxScrollExtent);
    }
  }

  /// 初始化弹幕接收事件
  void initDanmau() {
    liveDanmaku.onMessage = onWSMessage;
    liveDanmaku.onClose = onWSClose;
    liveDanmaku.onReady = onWSReady;
  }

  /// 接收到WebSocket信息
  void onWSMessage(LiveMessage msg) {
    if (msg.type == LiveMessageType.chat) {
      if (messages.length > 200 && !disableAutoScroll.value) {
        messages.removeAt(0);
      }

      // 关键词屏蔽检查
      for (var keyword in AppSettingsController.instance.shieldList) {
        Pattern? pattern;
        if (Utils.isRegexFormat(keyword)) {
          String removedSlash = Utils.removeRegexFormat(keyword);
          try {
            pattern = RegExp(removedSlash);
          } catch (e) {
            // should avoid this during add keyword
            Log.d("关键词：$keyword 正则格式错误");
          }
        } else {
          pattern = keyword;
        }
        if (pattern != null && msg.message.contains(pattern)) {
          Log.d("关键词：$keyword\n已屏蔽消息内容：${msg.message}");
          return;
        }
      }

      messages.add(msg);

      WidgetsBinding.instance.addPostFrameCallback(
        (_) => chatScrollToBottom(),
      );
      if (!liveStatus.value || isBackground) {
        return;
      }

      addDanmaku([
        DanmakuContentItem(
          msg.message,
          color: Color.fromARGB(
            255,
            msg.color.r,
            msg.color.g,
            msg.color.b,
          ),
        ),
      ]);
    } else if (msg.type == LiveMessageType.online) {
      online.value = msg.data;
    } else if (msg.type == LiveMessageType.superChat) {
      superChats.add(msg.data);
    }
  }

  /// 添加一条系统消息
  void addSysMsg(String msg) {
    messages.add(
      LiveMessage(
        type: LiveMessageType.chat,
        userName: "LiveSysMessage",
        message: msg,
        color: LiveMessageColor.white,
      ),
    );
  }

  /// 接收到WebSocket关闭信息
  void onWSClose(String msg) {
    addSysMsg(msg);
  }

  /// WebSocket准备就绪
  void onWSReady() {
    addSysMsg("弹幕服务器连接正常");
  }

  /// 加载直播间信息
  Future<void> loadData() async {
    if (_inactive) return;
    final load = Object();
    _roomLoad = load;
    final context = _roomContext;
    try {
      SmartDialog.showLoading(msg: "");
      loadError.value = false;
      errorMsg.value = '';
      recoveryMessage.value = '';
      error = null;
      update();
      addSysMsg("正在读取直播间信息");
      final loadedDetail = await site.liveSite.getRoomDetail(roomId: roomId);
      if (_inactive || context != _roomContext) return;
      detail.value = loadedDetail;

      if (site.id == Constant.kDouyin) {
        // 1.6.0之前收藏的WebRid
        // 1.6.0收藏的RoomID
        // 1.6.0之后改回WebRid
        if (detail.value!.roomId != roomId && !roomId.startsWith('user:')) {
          var oldId = roomId;
          rxRoomId.value = detail.value!.roomId;
          if (followed.value) {
            // 更新关注列表
            DBService.instance.deleteFollow("${site.id}_$oldId");
            DBService.instance.addFollow(
              FollowUser(
                id: "${site.id}_$roomId",
                roomId: roomId,
                siteId: site.id,
                userName: detail.value!.userName,
                face: detail.value!.userAvatar,
                addTime: DateTime.now(),
              ),
            );
          } else {
            followed.value =
                DBService.instance.getFollowExist("${site.id}_$roomId");
          }
        }
      }

      getSuperChatMessage();

      addHistory();
      // 确认房间关注状态
      followed.value = DBService.instance.getFollowExist("${site.id}_$roomId");
      online.value = detail.value!.online;
      liveStatus.value = detail.value!.status || detail.value!.isRecord;

      if (detail.value!.isRecord) {
        addSysMsg("当前主播未开播，正在轮播录像");
      }
      if (liveStatus.value) {
        addSysMsg("开始连接弹幕服务器");
        initDanmau();
        liveDanmaku.start(detail.value?.danmakuData);
        startLiveDurationTimer();
        await getPlayQualites();
      }
    } catch (e, stackTrace) {
      if (_inactive || context != _roomContext) return;
      Log.logPrint(e);
      //SmartDialog.showToast(e.toString());
      loadError.value = true;
      error = e;
      loadErrorTrace = stackTrace;
    } finally {
      if (identical(_roomLoad, load)) _roomLoad = null;
      SmartDialog.dismiss(status: SmartStatus.loading);
    }
  }

  /// 初始化播放器
  Future<void> getPlayQualites() async {
    if (_inactive) return;
    qualites.clear();
    currentQuality = -1;
    final context = _roomContext;

    try {
      var playQualites =
          await site.liveSite.getPlayQualites(detail: detail.value!);

      if (_inactive || context != _roomContext) return;
      if (playQualites.isEmpty) {
        SmartDialog.showToast("无法读取播放清晰度");
        return;
      }
      qualites.value = playQualites;
      var qualityLevel = await getQualityLevel();
      if (_inactive || context != _roomContext) return;
      if (qualityLevel == 2) {
        //最高
        currentQuality = 0;
      } else if (qualityLevel == 0) {
        //最低
        currentQuality = playQualites.length - 1;
      } else {
        //中间值
        int middle = (playQualites.length / 2).floor();
        currentQuality = middle;
      }

      final preferences = PlaybackPreferences.read(site.id, roomId);
      smoothPlayback.value = preferences['smooth'] == true;
      _preferredLine = preferences['line'] as String?;
      _preferredQuality = preferences['quality'] as String?;
      currentQuality = PlaybackSource.qualityIndexFor(
          playQualites, _preferredQuality,
          fallback: currentQuality);
      _preferredQuality ??= playQualites[currentQuality].quality;
      qualityNotice.value = '';
      await getPlayUrl();
    } catch (e) {
      if (_inactive || context != _roomContext) return;
      Log.logPrint(e);
      SmartDialog.showToast("无法读取播放清晰度");
    }
  }

  Future<int> getQualityLevel() async {
    var qualityLevel = AppSettingsController.instance.qualityLevel.value;
    try {
      var connectivityResult = await (Connectivity().checkConnectivity());
      if (connectivityResult.first == ConnectivityResult.mobile) {
        qualityLevel =
            AppSettingsController.instance.qualityLevelCellular.value;
      }
    } catch (e) {
      Log.logPrint(e);
    }
    return qualityLevel;
  }

  Future<void> getPlayUrl() async {
    if (_inactive || currentQuality < 0 || currentQuality >= qualites.length) {
      return;
    }
    _stopPlayUrlRefreshTimer();
    playUrls.clear();
    currentQualityInfo.value = qualites[currentQuality].quality;
    currentLineInfo.value = "";
    currentLineIndex = -1;
    final context = _playContext;
    if (!await _refreshPlayUrl()) {
      if (_inactive || context != _playContext) return;
      errorMsg.value = '暂时无法获取播放地址，请重试或检查账号状态';
      return;
    }
    if (_inactive || context != _playContext) return;
    // An explicit room/quality change resets the recovery budget.
    _recovery.reset();
    await initPlaylist();
    _startPlayUrlRefreshTimer();
  }

  void _startPlayUrlRefreshTimer() {
    _playUrlRefreshTimer?.cancel();
    _playUrlRefreshTimer = null;
    if (site.id != Constant.kDouyu ||
        isBackground ||
        currentLineIndex < 0 ||
        currentLineIndex >= playUrls.length) {
      return;
    }
    final info = _activePlayUrl?.infoForUrl(playUrls[currentLineIndex]);
    if (info == null) return;
    final delay = PlaybackRefreshPolicy.prefetchDelay(info);
    if (delay == null) return;
    final context = _playContext;
    _playUrlRefreshTimer = Timer(delay, () {
      if (_inactive ||
          context != _playContext ||
          !liveStatus.value ||
          isBackground ||
          _handlingMediaFailure) {
        return;
      }
      // Fetch metadata only. Do not open another player or rebuild the Video.
      unawaited(_refreshPlayUrl(refreshRoomDetail: true, preload: true));
    });
  }

  void _stopPlayUrlRefreshTimer({bool invalidateRequests = true}) {
    _playUrlRefreshTimer?.cancel();
    _playUrlRefreshTimer = null;
    _healthyPlaybackTimer?.cancel();
    if (invalidateRequests) {
      _playGeneration++;
      _recovery.reset();
      _retryDelayTimer?.cancel();
      _retryDelayTimer = null;
      _retryDelay?.complete();
      _retryDelay = null;
      _playbackHealth.reset();
      _recoveryReason = 'selection';
      _lastOpenedAt = null;
      _pendingFailureContext = null;
      _deferredFailureTimer?.cancel();
    }
    _preloadedPlayUrl = null;
    _preloadedAt = null;
    _preloadedContext = null;
  }

  bool _consumePreloadedPlayUrl() {
    final snapshot = _preloadedPlayUrl;
    final sources = snapshot?.urls;
    final received = _preloadedAt;
    final context = _preloadedContext;
    _preloadedPlayUrl = null;
    _preloadedAt = null;
    _preloadedContext = null;
    if (sources == null ||
        received == null ||
        context != _playContext ||
        sources.urls.isEmpty) {
      return false;
    }
    final line = _selectSourceLine(sources);
    if (!PlaybackRefreshPolicy.canUsePrefetched(
        sources.infoForUrl(sources.urls[line]), received)) {
      return false;
    }
    _applyPlayUrl(snapshot!);
    return true;
  }

  void _applyPlayUrl(PlaybackSource snapshot) {
    final sources = snapshot.urls;
    final index = _selectSourceLine(sources);
    _activePlayUrl = sources;
    detail.value = snapshot.detail;
    online.value = snapshot.detail.online;
    qualites.assignAll(snapshot.qualities);
    currentQuality = snapshot.qualityIndex;
    playUrls.value = List.of(sources.urls);
    playHeaders = sources.headers;
    currentLineIndex = index;
    _updateSourceInfo();
  }

  void _updateSourceInfo() {
    if (currentLineIndex < 0 || currentLineIndex >= playUrls.length) return;
    final info = _activePlayUrl?.infoForUrl(playUrls[currentLineIndex]);
    currentLineInfo.value = info?.cdn?.isNotEmpty == true
        ? info!.cdn!
        : '线路${currentLineIndex + 1}';
    final requested = currentQuality >= 0 && currentQuality < qualites.length
        ? qualites[currentQuality].quality
        : '';
    currentQualityInfo.value = info?.displayedQuality(requested) ?? requested;
    if (info?.limitationReason?.isNotEmpty == true) {
      qualityNotice.value = info!.limitationReason!;
    } else if (info?.actualQuality != null &&
        info!.actualQuality != requested) {
      qualityNotice.value = '平台返回了${info.actualQuality}，请求画质为$requested';
      if (PlatformAccountManager.instance.account(site.id).status ==
          LiveAccountStatus.expired) {
        qualityNotice.value += '；登录已失效，请重新登录';
      }
    } else if (_preferredQuality != null && requested != _preferredQuality) {
      qualityNotice.value = '当前使用$requested，偏好画质为$_preferredQuality';
    } else {
      qualityNotice.value = '';
    }
  }

  Future<PlaybackSource?> _fetchPlayUrl(
      String context, bool refreshRoomDetail) async {
    final requestedSite = site.liveSite;
    final selectedQuality = qualites[currentQuality];
    try {
      final PlaybackSource? snapshot;
      if (refreshRoomDetail) {
        snapshot = await PlaybackSource.refresh(
            requestedSite, roomId, selectedQuality,
            allowQualityFallback: smoothPlayback.value);
      } else {
        final requestedDetail = detail.value!;
        final qualities = List<LivePlayQuality>.of(qualites);
        final index = currentQuality;
        final urls = await requestedSite.getPlayUrls(
            detail: requestedDetail, quality: selectedQuality);
        snapshot = PlaybackSource(
            detail: requestedDetail,
            qualities: qualities,
            qualityIndex: index,
            urls: urls);
      }
      if (snapshot == null ||
          _inactive ||
          context != _playContext ||
          snapshot.urls.urls.isEmpty) {
        return null;
      }
      if (snapshot.urls.accountSessionVersion != null &&
          snapshot.urls.accountSessionVersion !=
              (requestedSite.accountSession?.version ?? 0)) {
        return null;
      }
      return snapshot;
    } catch (e) {
      Log.logPrint(e);
      return null;
    }
  }

  /// Share a pending fetch within one room/quality/account revision only.
  Future<bool> _refreshPlayUrl(
      {bool refreshRoomDetail = false, bool preload = false}) async {
    if (_inactive ||
        detail.value == null ||
        currentQuality < 0 ||
        currentQuality >= qualites.length) {
      return false;
    }
    final context = _playContext;
    final Future<PlaybackSource?> request;
    if (_pendingPlayContext == context && _pendingPlayUrl != null) {
      request = _pendingPlayUrl!;
    } else {
      request = _fetchPlayUrl(context, refreshRoomDetail);
      _pendingPlayUrl = request;
      _pendingPlayContext = context;
    }
    try {
      final sources = await request;
      if (sources == null || _inactive || context != _playContext) return false;
      if (preload) {
        _preloadedPlayUrl = sources;
        _preloadedAt = DateTime.now();
        _preloadedContext = context;
      } else {
        _preloadedPlayUrl = null;
        _preloadedAt = null;
        _preloadedContext = null;
        _applyPlayUrl(sources);
      }
      return true;
    } finally {
      if (identical(_pendingPlayUrl, request)) {
        _pendingPlayUrl = null;
        _pendingPlayContext = null;
      }
    }
  }

  void _observeHealthyPlayback() {
    _healthyPlaybackTimer?.cancel();
    _playbackHealth.reset();
    final context = _playContext;
    final sequence = _sourceSequence;
    _healthyPlaybackTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (_inactive || context != _playContext || sequence != _sourceSequence) {
        timer.cancel();
        return;
      }
      final state = player.state;
      final health = _playbackHealth.sample(
        now: playbackNow,
        position: state.position,
        playing: state.playing,
        buffering: state.buffering,
        completed: state.completed,
        suspended: isBackground || _openingContext != null,
      );
      if (health.progressing) {
        recoveryMessage.value = '';
      }
      if (health.stable && _recovery.attempts > 0) {
        _logPlayback('stable');
        _recovery.reset(clearLines: false);
      }
      // Continue observing after the initial healthy minute: decode failures
      // in a long session may never emit media_kit's stream.error or EOF.
      if (health.decoderStalled &&
          !_handlingMediaFailure &&
          !_recovery.stopped) {
        _queueMediaFailure(reason: 'decoder-stall', confirmed: true);
      }
    });
    _startPlayUrlRefreshTimer();
  }

  @override
  void mediaDecoderError() {
    if (_inactive ||
        isBackground ||
        !liveStatus.value ||
        _openingContext != null ||
        _handlingMediaFailure ||
        !player.state.playing) {
      return;
    }
    _playbackHealth.decoderError(playbackNow);
  }

  Future<void> changePlayLine(int index) async {
    if (_inactive || index < 0 || index >= playUrls.length) return;
    _stopPlayUrlRefreshTimer();
    final context = _playContext;
    final oldLineIndex = currentLineIndex;
    currentLineIndex = index;
    _recovery.reset();
    // An unused alternative may have expired while the active line stayed live.
    // Obtain fresh sources for every explicit line switch.
    if (!await _refreshPlayUrl(refreshRoomDetail: true)) {
      if (!_inactive && context == _playContext) {
        currentLineIndex = oldLineIndex;
        _updateSourceInfo();
        _observeHealthyPlayback();
        SmartDialog.showToast('无法读取新线路，请重试');
      }
      return;
    }
    if (_inactive || context != _playContext) return;
    await PlaybackPreferences.save(site.id, roomId, {'line': _lineIdentity});
    if (_inactive || context != _playContext) return;
    _preferredLine = _lineIdentity;
    await setPlayer();
  }

  Future<void> initPlaylist() => setPlayer();

  Future<void> setPlayer() async {
    if (_inactive ||
        currentLineIndex < 0 ||
        currentLineIndex >= playUrls.length) {
      return;
    }
    final context = _playContext;
    final targetPlayer = player;
    var url = playUrls[currentLineIndex];
    if (AppSettingsController.instance.playerForceHttps.value) {
      url = url.replaceFirst('http://', 'https://');
    }
    final media = Media(url, httpHeaders: playHeaders);
    bool isCurrent() =>
        !_inactive &&
        context == _playContext &&
        identical(player, targetPlayer);
    try {
      await _playerCommands.run(
          isCurrent: isCurrent,
          command: () async {
            _openingContext = context;
            _sourceSequence++;
            _playbackHealth.reset();
            _deferredFailureTimer?.cancel();
            try {
              await initializePlayer(targetPlayer);
              if (!isCurrent()) return;
              errorMsg.value = '';
              // Keep a single source open, so native playlist auto-advance cannot
              // silently change the selected CDN, expiry or displayed quality.
              _logPlayback('open');
              await targetPlayer.open(media);
              if (!isCurrent()) return;
              _lastOpenedAt = playbackNow;
              _updateSourceInfo();
              _observeHealthyPlayback();
            } finally {
              if (_openingContext == context) _openingContext = null;
              if (_pendingFailureContext == context) {
                _pendingFailureContext = null;
                if (isCurrent()) {
                  _scheduleFailureCheck(context, _sourceSequence);
                }
              }
            }
          });
    } catch (e) {
      if (isCurrent()) {
        errorMsg.value = '播放中断，请刷新重试';
        _lastOpenedAt = playbackNow;
        _recoveryReason = 'open-error';
        _scheduleFailureCheck(context, _sourceSequence, force: true);
      }
      Log.logPrint(e);
    }
  }

  int get mediaErrorRetryCount => _recovery.attempts;

  DateTime get playbackNow => DateTime.now();

  void _logPlayback(String event) {
    final state = player.state;
    final info = currentLineIndex >= 0 && currentLineIndex < playUrls.length
        ? _activePlayUrl?.infoForUrl(playUrls[currentLineIndex])
        : null;
    final age = info?.fetchedAt == null
        ? null
        : playbackNow.difference(info!.fetchedAt!).inSeconds;
    Log.d(
        '[Playback] $event site=${site.id} room=$roomId source=$_sourceSequence '
        'line=${_lineIdentity ?? "unknown"} quality=${currentQualityInfo.value} '
        'reason=$_recoveryReason attempt=${_recovery.attempts} '
        'recurring=${_recovery.hasRecurringFailure(_lineIdentity, playbackNow)} '
        'selection=${_recovery.selectionReason} candidates=${playUrls.length} '
        'urlAgeSeconds=$age expiresInSeconds=${info?.expiresInSeconds} '
        'accountAttached=${site.liveSite.accountSession != null} '
        'positionMs=${state.position.inMilliseconds} '
        'playing=${state.playing} buffering=${state.buffering} '
        'completed=${state.completed}');
  }

  int _selectSourceLine(LivePlayUrl sources) {
    final identity = _lineIdentity ?? _preferredLine;
    return _handlingMediaFailure
        ? _recovery.selectLine(
            sources.urls.map(sources.identityForUrl).toList(),
            identity,
            playbackNow)
        : sources.indexForIdentity(identity);
  }

  /// 播放器可能同时报告 error 和 completed，避免同一次断流触发两轮重试。
  String? _failureContext;
  bool get _handlingMediaFailure => _failureContext == _playContext;

  Future<bool?> _getLiveStatus() async {
    try {
      return await site.liveSite.getLiveStatus(roomId: roomId);
    } catch (e) {
      Log.logPrint(e);
      return null;
    }
  }

  Future<void> _waitForRetry(Duration duration) {
    if (duration == Duration.zero) return Future.value();
    final completion = Completer<void>();
    _retryDelay = completion;
    _retryDelayTimer = Timer(duration, () {
      if (identical(_retryDelay, completion)) {
        _retryDelay = null;
        _retryDelayTimer = null;
      }
      completion.complete();
    });
    return completion.future;
  }

  Future<void> _handleMediaFailure() async {
    if (_handlingMediaFailure ||
        _recovery.stopped ||
        _inactive ||
        _roomLoad != null ||
        !liveStatus.value) {
      return;
    }
    final context = _playContext;
    _failureContext = context;
    _recovery.failed(_lineIdentity, playbackNow);
    _logPlayback('recover');
    errorMsg.value = '';
    recoveryMessage.value = '播放中断，正在恢复…';
    _healthyPlaybackTimer?.cancel();
    try {
      final maxAttempts = (playUrls.length + 1).clamp(2, 5);
      while (_recovery.attempts < maxAttempts) {
        final delay = _recovery.retryDelay;
        await _waitForRetry(delay);
        if (_inactive || context != _playContext) return;
        _recovery.attempts++;
        final refreshed = _consumePreloadedPlayUrl() ||
            await _refreshPlayUrl(refreshRoomDetail: true);
        if (_inactive || context != _playContext) return;
        if (refreshed) {
          await initPlaylist();
          return;
        }
        // Do not reopen a known stale URL when a fresh request failed.
      }
      _recovery.stopped = true;
      _logPlayback('exhausted');
      final status = await _getLiveStatus();
      if (_inactive || context != _playContext) return;
      if (status == false) {
        liveStatus.value = false;
        _stopPlayUrlRefreshTimer();
      } else if (status == true &&
          smoothPlayback.value &&
          currentQuality + 1 < qualites.length) {
        recoveryMessage.value = '线路恢复失败，正在尝试较低画质…';
        await selectQuality(currentQuality + 1, remember: false);
        return;
      } else {
        errorMsg.value = status == null
            ? '网络异常，暂时无法确认直播状态；连接恢复后将重试'
            : '直播仍在进行，线路暂时不可用，请重试或切换画质';
      }
      recoveryMessage.value = '';
    } catch (e) {
      if (!_inactive && context == _playContext) {
        errorMsg.value = '播放中断，请刷新重试';
      }
      Log.logPrint(e);
    } finally {
      if (_failureContext == context) _failureContext = null;
      if (!_inactive && context == _playContext && errorMsg.value.isNotEmpty) {
        recoveryMessage.value = '';
      }
    }
  }

  // EOF is terminal. Other native errors can be recoverable; observe actual
  // progress before reopening. Old-source events during open are coalesced.
  void _queueMediaFailure({required String reason, bool confirmed = false}) {
    if (_inactive || !liveStatus.value || _recovery.stopped) return;
    final context = _playContext;
    final justOpened = _lastOpenedAt != null &&
        playbackNow.difference(_lastOpenedAt!) < const Duration(seconds: 1);
    _recoveryReason = reason;
    if (_openingContext == context) {
      _pendingFailureContext = context;
      return;
    }
    if (justOpened) {
      _scheduleFailureCheck(context, _sourceSequence);
      return;
    }
    if (_handlingMediaFailure) return;
    if (!confirmed) {
      _scheduleFailureCheck(context, _sourceSequence);
      return;
    }
    unawaited(_handleMediaFailure());
  }

  void _scheduleFailureCheck(String context, int sequence,
      {bool force = false, DateTime? observedAt}) {
    if ((_deferredFailureTimer?.isActive ?? false) && !force) return;
    _deferredFailureTimer?.cancel();
    // Sample only after open completed: a new source resets its position.
    final position = player.state.position;
    final firstObserved = observedAt ?? playbackNow;
    _deferredFailureTimer = Timer(const Duration(seconds: 3), () {
      _deferredFailureTimer = null;
      if (_inactive ||
          context != _playContext ||
          sequence != _sourceSequence ||
          _recovery.stopped) {
        return;
      }
      if (_roomLoad != null || _openingContext == context) {
        _scheduleFailureCheck(context, sequence,
            force: force, observedAt: firstObserved);
      } else if (!force &&
          !player.state.completed &&
          player.state.buffering &&
          playbackNow.difference(firstObserved) < const Duration(seconds: 12)) {
        _scheduleFailureCheck(context, sequence, observedAt: firstObserved);
      } else if (force ||
          player.state.completed ||
          (player.state.playing &&
              !isBackground &&
              player.state.position <= position)) {
        unawaited(_handleMediaFailure());
      }
    });
  }

  @override
  void mediaEnd() {
    if (player.state.completed) {
      _queueMediaFailure(reason: 'eof', confirmed: true);
    }
  }

  @override
  void mediaError(String error) {
    _queueMediaFailure(reason: 'native-error');
  }

  /// 读取SC
  void getSuperChatMessage() async {
    try {
      var sc =
          await site.liveSite.getSuperChatMessage(roomId: detail.value!.roomId);
      superChats.addAll(sc);
    } catch (e) {
      Log.logPrint(e);
      addSysMsg("SC读取失败");
    }
  }

  /// 移除掉已到期的SC
  void removeSuperChats() async {
    var now = DateTime.now().millisecondsSinceEpoch;
    superChats.value = superChats
        .where((x) => x.endTime.millisecondsSinceEpoch > now)
        .toList();
  }

  /// 添加历史记录
  void addHistory() {
    if (detail.value == null) {
      return;
    }
    var id = "${site.id}_$roomId";
    var history = DBService.instance.getHistory(id);
    if (history != null) {
      history.updateTime = DateTime.now();
    }
    history ??= History(
      id: id,
      roomId: roomId,
      siteId: site.id,
      userName: detail.value?.userName ?? "",
      face: detail.value?.userAvatar ?? "",
      updateTime: DateTime.now(),
    );

    DBService.instance.addOrUpdateHistory(history);
  }

  /// 关注用户
  void followUser() {
    if (detail.value == null) {
      return;
    }
    var id = "${site.id}_$roomId";
    DBService.instance.addFollow(
      FollowUser(
        id: id,
        roomId: roomId,
        siteId: site.id,
        userName: detail.value?.userName ?? "",
        face: detail.value?.userAvatar ?? "",
        addTime: DateTime.now(),
      ),
    );
    followed.value = true;
    EventBus.instance.emit(Constant.kUpdateFollow, id);
  }

  /// 取消关注用户
  void removeFollowUser() async {
    if (detail.value == null) {
      return;
    }
    if (!await Utils.showAlertDialog("确定要取消关注该用户吗？", title: "取消关注")) {
      return;
    }

    var id = "${site.id}_$roomId";
    DBService.instance.deleteFollow(id);
    followed.value = false;
    EventBus.instance.emit(Constant.kUpdateFollow, id);
  }

  void share() {
    if (detail.value == null) {
      return;
    }
    SharePlus.instance.share(ShareParams(uri: Uri.parse(detail.value!.url)));
  }

  void copyUrl() {
    if (detail.value == null) {
      return;
    }
    Utils.copyToClipboard(detail.value!.url);
    SmartDialog.showToast("已复制直播间链接");
  }

  /// 复制新生成的直播流
  void copyPlayUrl() async {
    // 未开播不复制
    if (!liveStatus.value) {
      return;
    }
    var playUrl = await site.liveSite
        .getPlayUrls(detail: detail.value!, quality: qualites[currentQuality]);
    if (playUrl.urls.isEmpty) {
      SmartDialog.showToast("无法读取播放地址");
      return;
    }
    Utils.copyToClipboard(playUrl.urls.first);
    SmartDialog.showToast("已复制播放直链");
  }

  /// 底部打开播放器设置
  void showDanmuSettingsSheet() {
    Utils.showBottomSheet(
      title: "弹幕设置",
      child: ListView(
        padding: AppStyle.edgeInsetsA12,
        children: [
          DanmuSettingsView(
            danmakuController: danmakuController,
            onTapDanmuShield: () {
              Get.back();
              showDanmuShield();
            },
          ),
        ],
      ),
    );
  }

  void showVolumeSlider(BuildContext targetContext) {
    SmartDialog.showAttach(
      targetContext: targetContext,
      alignment: Alignment.topCenter,
      displayTime: const Duration(seconds: 3),
      maskColor: const Color(0x00000000),
      builder: (context) {
        return Container(
          decoration: BoxDecoration(
            borderRadius: AppStyle.radius12,
            color: Theme.of(context).cardColor,
          ),
          padding: AppStyle.edgeInsetsA4,
          child: Obx(
            () => SizedBox(
              width: 200,
              child: Slider(
                min: 0,
                max: 100,
                value: AppSettingsController.instance.playerVolume.value,
                onChanged: (newValue) {
                  player.setVolume(newValue);
                  AppSettingsController.instance.setPlayerVolume(newValue);
                },
              ),
            ),
          ),
        );
      },
    );
  }

  void showQualitySheet() {
    Utils.showBottomSheet(
      title: '画质与播放策略',
      child: Obx(() => ListView(children: [
            ListTile(
                title: Text('当前播放：${currentQualityInfo.value}'),
                subtitle: Text(qualityNotice.value.isEmpty
                    ? '画质选择会记住在此直播间'
                    : qualityNotice.value),
                trailing: qualityNotice.value.isEmpty
                    ? null
                    : TextButton(
                        onPressed: () {
                          Get.back();
                          restorePreferredQuality();
                        },
                        child: const Text('恢复偏好'))),
            SwitchListTile(
                title: Text(smoothPlayback.value ? '流畅优先' : '画质优先'),
                subtitle: const Text('开启后，同画质线路多次失败时允许自动降低画质'),
                value: smoothPlayback.value,
                onChanged: (value) {
                  smoothPlayback.value = value;
                  PlaybackPreferences.save(site.id, roomId, {'smooth': value});
                }),
            RadioGroup<int>(
                groupValue: currentQuality,
                onChanged: (value) {
                  Get.back();
                  selectQuality(value ?? 0);
                },
                child: Column(children: [
                  for (var i = 0; i < qualites.length; i++)
                    RadioListTile<int>(
                        value: i, title: Text(qualites[i].quality))
                ])),
          ])),
    );
  }

  void showPlayUrlsSheet() {
    Utils.showBottomSheet(
      title: "切换线路",
      child: RadioGroup(
        groupValue: currentLineIndex,
        onChanged: (e) {
          Get.back();
          //currentLineIndex = i;
          //setPlayer();
          changePlayLine(e ?? 0);
        },
        child: ListView.builder(
          itemCount: playUrls.length,
          itemBuilder: (_, i) {
            return RadioListTile(
              value: i,
              title: Text(
                  _activePlayUrl?.infoForUrl(playUrls[i]).cdn ?? "线路${i + 1}"),
              subtitle: Text(_activePlayUrl
                      ?.infoForUrl(playUrls[i])
                      .displayedQuality(qualites[currentQuality].quality) ??
                  ''),
              secondary: Text(
                playUrls[i].contains(".flv") ? "FLV" : "HLS",
              ),
            );
          },
        ),
      ),
    );
  }

  void showPlayerSettingsSheet() {
    Utils.showBottomSheet(
      title: "画面尺寸",
      child: Obx(
        () => RadioGroup(
          groupValue: AppSettingsController.instance.scaleMode.value,
          onChanged: (e) {
            AppSettingsController.instance.setScaleMode(e ?? 0);
            updateScaleMode();
          },
          child: ListView(
            padding: AppStyle.edgeInsetsV12,
            children: const [
              RadioListTile(
                value: 0,
                title: Text("适应"),
                visualDensity: VisualDensity.compact,
              ),
              RadioListTile(
                value: 1,
                title: Text("拉伸"),
                visualDensity: VisualDensity.compact,
              ),
              RadioListTile(
                value: 2,
                title: Text("铺满"),
                visualDensity: VisualDensity.compact,
              ),
              RadioListTile(
                value: 3,
                title: Text("16:9"),
                visualDensity: VisualDensity.compact,
              ),
              RadioListTile(
                value: 4,
                title: Text("4:3"),
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),
        ),
      ),
    );
  }

  void showDanmuShield() {
    TextEditingController keywordController = TextEditingController();

    void addKeyword() {
      if (keywordController.text.isEmpty) {
        SmartDialog.showToast("请输入关键词");
        return;
      }

      AppSettingsController.instance
          .addShieldList(keywordController.text.trim());
      keywordController.text = "";
    }

    Utils.showBottomSheet(
      title: "关键词屏蔽",
      child: ListView(
        padding: AppStyle.edgeInsetsA12,
        children: [
          TextField(
            controller: keywordController,
            decoration: InputDecoration(
              contentPadding: AppStyle.edgeInsetsH12,
              border: const OutlineInputBorder(),
              hintText: "请输入关键词",
              suffixIcon: TextButton.icon(
                onPressed: addKeyword,
                icon: const Icon(Icons.add),
                label: const Text("添加"),
              ),
            ),
            onSubmitted: (e) {
              addKeyword();
            },
          ),
          AppStyle.vGap12,
          Obx(
            () => Text(
              "已添加${AppSettingsController.instance.shieldList.length}个关键词（点击移除）",
              style: Get.textTheme.titleSmall,
            ),
          ),
          AppStyle.vGap12,
          Obx(
            () => Wrap(
              runSpacing: 12,
              spacing: 12,
              children: AppSettingsController.instance.shieldList
                  .map(
                    (item) => InkWell(
                      borderRadius: AppStyle.radius24,
                      onTap: () {
                        AppSettingsController.instance.removeShieldList(item);
                      },
                      child: Container(
                        decoration: BoxDecoration(
                          border: Border.all(color: Colors.grey),
                          borderRadius: AppStyle.radius24,
                        ),
                        padding: AppStyle.edgeInsetsH12.copyWith(
                          top: 4,
                          bottom: 4,
                        ),
                        child: Text(
                          item,
                          style: Get.textTheme.bodyMedium,
                        ),
                      ),
                    ),
                  )
                  .toList(),
            ),
          ),
        ],
      ),
    );
  }

  void showFollowUserSheet() {
    Utils.showBottomSheet(
      title: "关注列表",
      child: Obx(
        () => Stack(
          children: [
            RefreshIndicator(
              onRefresh: FollowService.instance.loadData,
              child: ListView.builder(
                itemCount: FollowService.instance.liveList.length,
                itemBuilder: (_, i) {
                  var item = FollowService.instance.liveList[i];
                  return Obx(
                    () => FollowUserItem(
                      item: item,
                      playing: rxSite.value.id == item.siteId &&
                          rxRoomId.value == item.roomId,
                      onTap: () {
                        Get.back();
                        resetRoom(
                          Sites.allSites[item.siteId]!,
                          item.roomId,
                        );
                      },
                    ),
                  );
                },
              ),
            ),
            if (Platform.isLinux || Platform.isWindows || Platform.isMacOS)
              Positioned(
                right: 12,
                bottom: 12,
                child: Obx(
                  () => DesktopRefreshButton(
                    refreshing: FollowService.instance.updating.value,
                    onPressed: FollowService.instance.loadData,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  void showAutoExitSheet() {
    if (AppSettingsController.instance.autoExitEnable.value &&
        !delayAutoExit.value) {
      SmartDialog.showToast("已设置了全局定时关闭");
      return;
    }
    Utils.showBottomSheet(
      title: "定时关闭",
      child: ListView(
        children: [
          Obx(
            () => SwitchListTile(
              title: Text(
                "启用定时关闭",
                style: Get.textTheme.titleMedium,
              ),
              value: autoExitEnable.value,
              onChanged: (e) {
                autoExitEnable.value = e;

                setAutoExit();
                //controller.setAutoExitEnable(e);
              },
            ),
          ),
          Obx(
            () => ListTile(
              enabled: autoExitEnable.value,
              title: Text(
                "自动关闭时间：${autoExitMinutes.value ~/ 60}小时${autoExitMinutes.value % 60}分钟",
                style: Get.textTheme.titleMedium,
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () async {
                var value = await showTimePicker(
                  context: Get.context!,
                  initialTime: TimeOfDay(
                    hour: autoExitMinutes.value ~/ 60,
                    minute: autoExitMinutes.value % 60,
                  ),
                  initialEntryMode: TimePickerEntryMode.inputOnly,
                  builder: (_, child) {
                    return MediaQuery(
                      data: Get.mediaQuery.copyWith(
                        alwaysUse24HourFormat: true,
                      ),
                      child: child!,
                    );
                  },
                );
                if (value == null || (value.hour == 0 && value.minute == 0)) {
                  return;
                }
                var duration =
                    Duration(hours: value.hour, minutes: value.minute);
                autoExitMinutes.value = duration.inMinutes;
                AppSettingsController.instance
                    .setRoomAutoExitDuration(autoExitMinutes.value);
                //setAutoExitDuration(duration.inMinutes);
                setAutoExit();
              },
            ),
          ),
        ],
      ),
    );
  }

  void openNaviteAPP() async {
    var naviteUrl = "";
    var webUrl = "";
    if (site.id == Constant.kBiliBili) {
      naviteUrl = "bilibili://live/${detail.value?.roomId}";
      webUrl = "https://live.bilibili.com/${detail.value?.roomId}";
    } else if (site.id == Constant.kDouyin) {
      var args = detail.value?.danmakuData as DouyinDanmakuArgs;
      naviteUrl = "snssdk1128://webcast_room?room_id=${args.roomId}";
      webUrl = "https://live.douyin.com/${args.webRid}";
    } else if (site.id == Constant.kHuya) {
      var args = detail.value?.danmakuData as HuyaDanmakuArgs;
      naviteUrl =
          "yykiwi://homepage/index.html?banneraction=https%3A%2F%2Fdiy-front.cdn.huya.com%2Fzt%2Ffrontpage%2Fcc%2Fupdate.html%3Fhyaction%3Dlive%26channelid%3D${args.subSid}%26subid%3D${args.subSid}%26liveuid%3D${args.subSid}%26screentype%3D1%26sourcetype%3D0%26fromapp%3Dhuya_wap%252Fclick%252Fopen_app_guide%26&fromapp=huya_wap/click/open_app_guide";
      webUrl = "https://www.huya.com/${detail.value?.roomId}";
    } else if (site.id == Constant.kDouyu) {
      naviteUrl =
          "douyulink://?type=90001&schemeUrl=douyuapp%3A%2F%2Froom%3FliveType%3D0%26rid%3D${detail.value?.roomId}";
      webUrl = "https://www.douyu.com/${detail.value?.roomId}";
    }
    try {
      await launchUrlString(naviteUrl, mode: LaunchMode.externalApplication);
    } catch (e) {
      Log.logPrint(e);
      SmartDialog.showToast("无法打开APP，将使用浏览器打开");
      await launchUrlString(webUrl, mode: LaunchMode.externalApplication);
    }
  }

  void resetRoom(Site site, String roomId) async {
    if (this.site == site && this.roomId == roomId) {
      return;
    }

    _stopPlayUrlRefreshTimer();
    rxSite.value = site;
    rxRoomId.value = roomId;
    _knownAccountRevision = _accountRevision;

    // 清除全部消息
    liveDanmaku.stop();
    messages.clear();
    superChats.clear();
    danmakuController?.clear();

    // 重新设置LiveDanmaku
    liveDanmaku = site.liveSite.getDanmaku();

    // Serialize stop with any previous open, and ignore a superseded reset.
    final context = _roomContext;
    final targetPlayer = player;
    await _playerCommands.run(
      isCurrent: () => !_inactive && context == _roomContext,
      command: targetPlayer.stop,
    );
    if (_inactive || context != _roomContext) return;
    loadData();
  }

  void copyErrorDetail() {
    Utils.copyToClipboard('''直播平台：${rxSite.value.name}
房间号：${rxRoomId.value}
错误信息：
${error?.toString()}
----------------
$loadErrorTrace''');
    SmartDialog.showToast("已复制错误信息");
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);

    if (state == AppLifecycleState.paused) {
      Log.d("进入后台");
      //进入后台，关闭弹幕
      danmakuController?.clear();
      // Pending initial loads remain valid while background playback is allowed.
      _stopPlayUrlRefreshTimer(invalidateRequests: false);
      isBackground = true;
    } else
    //返回前台
    if (state == AppLifecycleState.resumed) {
      Log.d("返回前台");
      isBackground = false;
      // Desktop focus changes also emit resumed, without a preceding pause.
      // Preserve the measured healthy interval when its observer is still live.
      if (!(_healthyPlaybackTimer?.isActive ?? false) &&
          !_handlingMediaFailure &&
          !_recovery.stopped &&
          _sourceSequence > 0) {
        _observeHealthyPlayback();
      }
    }
  }

  // 用于启动开播时长计算和更新的函数
  void startLiveDurationTimer() {
    // 如果不是直播状态或者 showTime 为空，则不启动定时器
    if (!(detail.value?.status ?? false) || detail.value?.showTime == null) {
      liveDuration.value = "00:00:00"; // 未开播时显示 00:00:00
      _liveDurationTimer?.cancel();
      return;
    }

    try {
      int startTimeStamp = int.parse(detail.value!.showTime!);
      // 取消之前的定时器
      _liveDurationTimer?.cancel();
      // 创建新的定时器，每秒更新一次
      _liveDurationTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
        int currentTimeStamp = DateTime.now().millisecondsSinceEpoch ~/ 1000;
        int durationInSeconds = currentTimeStamp - startTimeStamp;

        int hours = durationInSeconds ~/ 3600;
        int minutes = (durationInSeconds % 3600) ~/ 60;
        int seconds = durationInSeconds % 60;

        String formattedDuration =
            '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
        liveDuration.value = formattedDuration;
      });
    } catch (e) {
      liveDuration.value = "--:--:--"; // 错误时显示 --:--:--
    }
  }

  @override
  void onClose() {
    _closing = true;
    _accountWorker?.dispose();
    _connectivitySubscription?.cancel();
    _stopPlayUrlRefreshTimer();
    WidgetsBinding.instance.removeObserver(this);
    scrollController.removeListener(scrollListener);
    autoExitTimer?.cancel();

    liveDanmaku.stop();
    danmakuController = null;
    _liveDurationTimer?.cancel(); // 页面关闭时取消定时器
    super.onClose();
  }
}
