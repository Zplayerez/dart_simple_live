import 'dart:async';

import 'package:simple_live_account/simple_live_account.dart';

import 'package:canvas_danmaku/models/danmaku_content_item.dart';
import 'package:flutter/material.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:media_kit/media_kit.dart';
import 'package:simple_live_core/simple_live_core.dart';
import 'package:simple_live_tv_app/app/constant.dart';
import 'package:simple_live_tv_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_tv_app/app/event_bus.dart';
import 'package:simple_live_tv_app/app/log.dart';
import 'package:simple_live_tv_app/app/sites.dart';
import 'package:simple_live_tv_app/app/utils.dart';
import 'package:simple_live_tv_app/models/db/follow_user.dart';
import 'package:simple_live_tv_app/models/db/history.dart';
import 'package:simple_live_tv_app/modules/live_room/player/player_controller.dart';
import 'package:simple_live_tv_app/services/db_service.dart';
import 'package:simple_live_tv_app/services/follow_user_service.dart';

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
  }
  final FocusNode focusNode = FocusNode();
  late Rx<Site> rxSite;
  Site get site => rxSite.value;
  late Rx<String> rxRoomId;
  String get roomId => rxRoomId.value;

  Rx<LiveRoomDetail?> detail = Rx<LiveRoomDetail?>(null);
  var online = 0.obs;
  var followed = false.obs;
  var liveStatus = false.obs;

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
  String? get _lineIdentity =>
      currentLineIndex >= 0 && currentLineIndex < playUrls.length
          ? _activePlayUrl?.identityForUrl(playUrls[currentLineIndex])
          : null;

  void _watchAccount() {
    _knownAccountRevision = _accountRevision;
    _accountWorker = ever(PlatformAccountManager.instance.accounts, (_) {
      final revision = _accountRevision;
      if (revision == _knownAccountRevision || _inactive) return;
      _knownAccountRevision = revision;
      // Verification alone does not change revision. Explicit account changes
      // invalidate signed URLs and reload this room once with the new session.
      refreshRoom();
    });
  }

  /// 当前线路
  var currentLineIndex = -1;
  var currentLineInfo = "".obs;

  /// 是否处于后台
  var isBackground = false;

  var datetime = "00:00".obs;

  Timer? _clockTimer;

  void initTimer() {
    _clockTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      var now = DateTime.now();
      datetime.value =
          "${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}";
    });
  }

  /// 双击退出Flag
  bool doubleClickExit = false;

  /// 双击退出Timer
  Timer? doubleClickTimer;

  @override
  void onInit() {
    _watchAccount();
    WidgetsBinding.instance.addObserver(this);
    initTimer();
    showDanmakuState.value = AppSettingsController.instance.danmuEnable.value;
    followed.value = DBService.instance.getFollowExist("${site.id}_$roomId");

    loadData();

    super.onInit();
  }

  void refreshRoom() {
    //messages.clear();

    _stopPlayUrlRefreshTimer();
    liveDanmaku.stop();

    loadData();
  }

  /// 初始化弹幕接收事件
  void initDanmau() {
    liveDanmaku.onMessage = onWSMessage;
  }

  /// 接收到WebSocket信息
  void onWSMessage(LiveMessage msg) {
    if (msg.type == LiveMessageType.chat) {
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

      if (!liveStatus.value || isBackground) {
        return;
      }

      addDanmaku([
        DanmakuContentItem(
          msg.message,
          color: Color.fromARGB(255, msg.color.r, msg.color.g, msg.color.b),
        ),
      ]);
    } else if (msg.type == LiveMessageType.online) {
      online.value = msg.data;
    } else if (msg.type == LiveMessageType.superChat) {
      //superChats.add(msg.data);
    }
  }

  /// 加载直播间信息
  Future<void> loadData() async {
    if (_inactive) return;
    final load = Object();
    _roomLoad = load;
    final context = _roomContext;
    try {
      SmartDialog.showLoading(msg: "");
      pageLoadding.value = true;
      final loadedDetail = await site.liveSite.getRoomDetail(roomId: roomId);
      if (_inactive || context != _roomContext) return;
      detail.value = loadedDetail;

      addHistory();
      online.value = detail.value!.online;
      liveStatus.value = detail.value!.status || detail.value!.isRecord;

      if (detail.value!.isRecord) {
        SmartDialog.showToast("当前主播未开播，正在轮播录像");
      }

      initDanmau();
      if (liveStatus.value) liveDanmaku.start(detail.value?.danmakuData);
      if (liveStatus.value) await getPlayQualites();
    } catch (e) {
      if (_inactive || context != _roomContext) return;
      Log.logPrint(e);
      SmartDialog.showToast("无法读取直播间信息");
    } finally {
      if (identical(_roomLoad, load)) _roomLoad = null;
      SmartDialog.dismiss(status: SmartStatus.loading);
      pageLoadding.value = false;
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
      var qualityLevel = AppSettingsController.instance.qualityLevel.value;
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

      await getPlayUrl();
    } catch (e) {
      if (_inactive || context != _roomContext) return;
      Log.logPrint(e);
      SmartDialog.showToast("无法读取播放清晰度");
    }
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
      SmartDialog.showToast("无法读取播放地址");
      return;
    }
    if (_inactive || context != _playContext) return;
    // An explicit room/quality change resets the recovery budget.
    _recovery.reset();
    await setPlayer();
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
    currentLineInfo.value = '线路${currentLineIndex + 1}';
    final requested = currentQuality >= 0 && currentQuality < qualites.length
        ? qualites[currentQuality].quality
        : '';
    currentQualityInfo.value = _activePlayUrl
            ?.infoForUrl(playUrls[currentLineIndex])
            .displayedQuality(requested) ??
        requested;
  }

  Future<PlaybackSource?> _fetchPlayUrl(
      String context, bool refreshRoomDetail) async {
    final requestedSite = site.liveSite;
    final selectedQuality = qualites[currentQuality];
    try {
      final PlaybackSource? snapshot;
      if (refreshRoomDetail) {
        snapshot = await PlaybackSource.refresh(
            requestedSite, roomId, selectedQuality);
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
    Log.d('[Playback] $event site=${site.id} source=$_sourceSequence '
        'line=${_lineIdentity ?? "unknown"} quality=${currentQualityInfo.value} '
        'reason=$_recoveryReason attempt=${_recovery.attempts} '
        'positionMs=${state.position.inMilliseconds} '
        'playing=${state.playing} buffering=${state.buffering} '
        'completed=${state.completed}');
  }

  int _selectSourceLine(LivePlayUrl sources) {
    final identity = _lineIdentity;
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
          await setPlayer();
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
      } else {
        errorMsg.value = '播放中断，请刷新重试';
      }
    } catch (e) {
      if (!_inactive && context == _playContext) {
        errorMsg.value = '播放中断，请刷新重试';
      }
      Log.logPrint(e);
    } finally {
      if (_failureContext == context) _failureContext = null;
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
    SmartDialog.showToast("已关注");
  }

  /// 取消关注用户
  void removeFollowUser() async {
    if (detail.value == null) {
      return;
    }
    // if (!await Utils.showAlertDialog("确定要取消关注该用户吗？", title: "取消关注")) {
    //   return;
    // }

    var id = "${site.id}_$roomId";
    DBService.instance.deleteFollow(id);
    followed.value = false;
    EventBus.instance.emit(Constant.kUpdateFollow, id);
    SmartDialog.showToast("已取消关注");
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

  void nextChannel() {
    //读取正在直播的频道
    var liveChannels = FollowUserService.instance.livingList;
    if (liveChannels.isEmpty) {
      SmartDialog.showToast("没有正在直播的频道");
      return;
    }
    var index = liveChannels
        .indexWhere((element) => element.id == "${site.id}_$roomId");
    // if (index == -1) {
    //   //当前频道不在列表中

    //   return;
    // }
    index += 1;
    if (index >= liveChannels.length) {
      index = 0;
    }
    var nextChannel = liveChannels[index];

    resetRoom(Sites.allSites[nextChannel.siteId]!, nextChannel.roomId);
  }

  void prevChannel() {
    //读取正在直播的频道
    var liveChannels = FollowUserService.instance.livingList;
    if (liveChannels.isEmpty) {
      SmartDialog.showToast("没有正在直播的频道");
      return;
    }
    var index = liveChannels
        .indexWhere((element) => element.id == "${site.id}_$roomId");
    // if (index == -1) {
    //   //当前频道不在列表中

    //   return;
    // }
    index -= 1;
    if (index < 0) {
      index = liveChannels.length - 1;
    }
    var nextChannel = liveChannels[index];

    resetRoom(Sites.allSites[nextChannel.siteId]!, nextChannel.roomId);
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

  @override
  void onClose() {
    _closing = true;
    WidgetsBinding.instance.removeObserver(this);
    _clockTimer?.cancel();
    _accountWorker?.dispose();
    _stopPlayUrlRefreshTimer();
    liveDanmaku.stop();

    danmakuController = null;
    super.onClose();
  }
}
