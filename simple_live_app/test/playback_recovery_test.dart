import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:logger/logger.dart';
import 'package:media_kit/media_kit.dart';
import 'package:simple_live_account/simple_live_account.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/modules/live_room/live_room_controller.dart';
import 'package:simple_live_core/simple_live_core.dart';
import 'package:simple_live_app/services/local_storage_service.dart';

class _Settings extends AppSettingsController {
  // Storage is not part of these playback tests.
  @override
  // ignore: must_call_super
  void onInit() {}
}

class _Store extends LocalStorageService {
  final values = <dynamic, dynamic>{};
  @override
  T getValue<T>(dynamic key, T defaultValue) =>
      values[key] as T? ?? defaultValue;
  @override
  Future setValue<T>(dynamic key, T value) async {
    values[key] = value;
  }
}

class _Site extends LiveSite {
  _Site() : super(id: 'douyu');
  List<String> lines = ['a', 'b'];
  int revision = 0;
  int statusCalls = 0;
  bool failFetch = false;
  Completer<void>? roomGate;
  Completer<void>? qualityGate;
  final scopes = <HttpRequestScope>[];
  bool? live = true;
  String? returnedQuality;
  List<String> qualityNames = ['原画'];
  String? rejectedQuality;

  @override
  Future<LiveRoomDetail> getRoomDetail({required String roomId}) async {
    final scope = HttpRequestScope.current;
    if (scope != null) scopes.add(scope);
    final gate = roomGate;
    if (gate != null) await gate.future;
    if (failFetch) throw StateError('synthetic provider failure');
    revision++;
    return LiveRoomDetail(
        roomId: roomId,
        title: '',
        cover: '',
        userName: '',
        userAvatar: '',
        online: 0,
        status: true,
        url: '',
        data: revision);
  }

  @override
  Future<List<LivePlayQuality>> getPlayQualites(
      {required LiveRoomDetail detail}) async {
    final scope = HttpRequestScope.current;
    if (scope != null) scopes.add(scope);
    final gate = qualityGate;
    if (gate != null) await gate.future;
    return [
      for (final name in qualityNames)
        LivePlayQuality(quality: name, data: null)
    ];
  }

  @override
  Future<LivePlayUrl> getPlayUrls(
      {required LiveRoomDetail detail,
      required LivePlayQuality quality}) async {
    if (quality.quality == rejectedQuality) {
      throw StateError('synthetic quality outage');
    }
    return LivePlayUrl(actualQuality: returnedQuality, urls: [
      for (final line in lines)
        'https://$line.invalid/live.flv?v=${detail.data}',
    ]);
  }

  @override
  Future<bool> getLiveStatus({required String roomId}) async {
    statusCalls++;
    if (live == null) throw StateError('synthetic network failure');
    return live!;
  }
}

class _Player extends PlatformPlayer {
  _Player() : super(configuration: const PlayerConfiguration());
  final opened = <String>[];
  bool failOpen = false;
  void Function()? duringOpen;
  @override
  Future<void> open(Playable playable, {bool play = true}) async {
    opened.add((playable as Media).uri);
    if (failOpen) throw StateError('synthetic open failure');
    state = const PlayerState(playing: true);
    duringOpen?.call();
  }

  @override
  Future<void> stop() async {
    state = const PlayerState();
  }
}

class _Room extends LiveRoomController {
  _Room(_Site site, this.native)
      : super(
          pSite: Site(id: site.id, name: 'fixture', logo: '', liveSite: site),
          pRoomId: '123',
        ) {
    player = Player(platformPlayer: native);
  }
  final _Player native;
  double? avSync;
  @override
  Future<double?> readAvSync() async => avSync;
  DateTime now = DateTime.utc(2026, 10, 7);
  @override
  DateTime get playbackNow => now;
  @override
  Future<void> initializePlayer([Player? targetPlayer]) async {}
  @override
  Future<void> resetSystem() async {}
}

void main() {
  late _Site site;
  late _Player native;
  late _Room room;
  setUp(() {
    PlaybackLineHistory.shared.clear();
    Get.testMode = true;
    Log.logger = Logger(level: Level.off);
    site = _Site();
    native = _Player();
    Get.put<AppSettingsController>(_Settings());
    Get.put<LocalStorageService>(_Store());
    Get.put(PlatformAccountManager(sites: {'douyu': site}));
  });
  tearDown(() => Get.reset());

  Future<void> open(WidgetTester tester) async {
    room = _Room(site, native);
    room.detail.value = await site.getRoomDetail(roomId: '123');
    room.qualites
        .assignAll(await site.getPlayQualites(detail: room.detail.value!));
    room.currentQuality = 0;
    room.liveStatus.value = true;
    await room.getPlayUrl();
    await tester.pump();
  }

  Future<void> tick(WidgetTester tester, int seconds,
      {bool advancing = true, int decoderErrors = 0}) async {
    for (var second = 0; second < seconds; second++) {
      room.now = room.now.add(const Duration(seconds: 1));
      if (advancing) {
        native.state = native.state.copyWith(
            position: native.state.position + const Duration(seconds: 1));
      }
      for (var n = 0; n < decoderErrors; n++) {
        room.handlePlayerLog(const PlayerLog(
            prefix: 'ffmpeg',
            level: 'error',
            text: 'NULL: reference count 1 overflow'));
      }
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
    }
  }

  void eof() {
    native.state = native.state.copyWith(playing: false, completed: true);
    room.mediaEnd();
  }

  Future<void> close(WidgetTester tester) async {
    room.onClose();
    await tester.pump();
  }

  testWidgets(
      'provider downgrade shows real quality and confirmed login expiry',
      (tester) async {
    site.returnedQuality = '蓝光4M';
    final accounts = PlatformAccountManager.instance;
    accounts.accounts['douyu'] = const PlatformAccountState(
        siteId: 'douyu',
        status: LiveAccountStatus.expired,
        hasCredential: true);
    await open(tester);
    expect(room.currentQualityInfo.value, '蓝光4M');
    expect(room.qualites[room.currentQuality].quality, '原画');
    expect(room.qualityNotice.value, contains('登录已失效，请重新登录'));
    await tick(tester, 5);
    expect(native.opened, hasLength(1));
    await close(tester);
  });

  testWidgets('recoverable native errors do not reopen advancing playback',
      (tester) async {
    await open(tester);
    await tick(tester, 2);
    room.mediaError('synthetic nonfatal error');
    await tick(tester, 5);
    expect(native.opened, hasLength(1));
    expect(room.mediaErrorRetryCount, 0);
    await close(tester);
  });

  testWidgets(
      'EOF and errors during open produce one recovery, not a second healthy reopen',
      (tester) async {
    await open(tester);
    await tick(tester, 2);
    native.duringOpen = () => room.mediaError('queued old-source error');
    eof();
    room.mediaError('duplicate network error');
    await tester.pump();
    await tick(tester, 5);
    expect(native.opened, hasLength(2));
    expect(room.mediaErrorRetryCount, 1);
    expect(native.opened.last, contains('v=2'));
    await close(tester);
  });

  testWidgets(
      'rapid failures back off, select fresh CDN identity and stop at the budget',
      (tester) async {
    await open(tester);
    await tick(tester, 2);
    eof();
    await tester.pump();
    expect(native.opened, hasLength(2));
    await tick(tester, 2);
    site.lines = ['b', 'a'];
    eof();
    await tester.pump();
    await tick(tester, 1, advancing: false);
    expect(native.opened, hasLength(2));
    await tick(tester, 1, advancing: false);
    expect(native.opened.last, startsWith('https://b.invalid/'));
    await tick(tester, 2);
    eof();
    await tester.pump();
    await tick(tester, 4, advancing: false);
    expect(native.opened, hasLength(4));
    await tick(tester, 2);
    eof();
    await tester.pump();
    expect(room.errorMsg.value, isNotEmpty);
    expect(room.liveStatus.value, isTrue);
    expect(site.statusCalls, 1);
    for (var n = 0; n < 20; n++) {
      room.mediaError('repeated failed source');
      room.mediaEnd();
    }
    await tick(tester, 20, advancing: false);
    expect(native.opened, hasLength(4));
    expect(site.statusCalls, 1);
    await close(tester);
  });

  testWidgets(
      'short recovery or a stuck playing flag does not reset the retry count',
      (tester) async {
    await open(tester);
    await tick(tester, 2);
    eof();
    await tester.pump();
    await tick(tester, 15);
    expect(room.mediaErrorRetryCount, 1);
    await tick(tester, 65, advancing: false);
    expect(room.mediaErrorRetryCount, 1);
    await tick(tester, 62);
    expect(room.mediaErrorRetryCount, 0);
    expect(native.opened, hasLength(2));
    await close(tester);
  });

  testWidgets(
      'persistent decoder errors recover once even when audio time advances',
      (tester) async {
    await open(tester);
    await tick(tester, 11, decoderErrors: 15);
    expect(native.opened, hasLength(2));
    expect(room.mediaErrorRetryCount, 1);
    await tick(tester, 5);
    expect(native.opened, hasLength(2));
    await close(tester);
  });

  testWidgets('one corrupt frame and a normal buffering interval do not reopen',
      (tester) async {
    await open(tester);
    await tick(tester, 2, decoderErrors: 1);
    native.state = native.state.copyWith(buffering: true);
    room.mediaError('temporary network error');
    await tick(tester, 6, advancing: false);
    expect(native.opened, hasLength(1));
    native.state = native.state.copyWith(buffering: false);
    await tick(tester, 6);
    expect(native.opened, hasLength(1));
    await close(tester);
  });

  testWidgets(
      'user pause and background playback are not mistaken for decoder stalls',
      (tester) async {
    await open(tester);
    await tick(tester, 2);
    native.state = native.state.copyWith(playing: false);
    room.mediaError('error while paused');
    await tick(tester, 15, advancing: false, decoderErrors: 20);
    expect(native.opened, hasLength(1));
    room.didChangeAppLifecycleState(AppLifecycleState.paused);
    native.state = native.state.copyWith(playing: true);
    await tick(tester, 15, decoderErrors: 20);
    room.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await tick(tester, 2);
    expect(native.opened, hasLength(1));
    await close(tester);
  });

  for (final status in <bool?>[true, false, null]) {
    testWidgets(
        'failed refresh never reopens expired URLs; live status=$status',
        (tester) async {
      await open(tester);
      await tick(tester, 2);
      site.failFetch = true;
      site.live = status;
      eof();
      await tester.pump();
      await tick(tester, 10, advancing: false);
      expect(native.opened, hasLength(1));
      expect(room.liveStatus.value, status != false);
      expect(site.statusCalls, 1);
      await close(tester);
    });
  }

  testWidgets(
      'failed player.open gets bounded retries even without playing or EOF flags',
      (tester) async {
    native.failOpen = true;
    await open(tester);
    await tick(tester, 25, advancing: false);
    expect(native.opened, hasLength(4));
    expect(room.errorMsg.value, isNotEmpty);
    await close(tester);
  });

  testWidgets('desktop focus changes preserve the measured healthy interval',
      (tester) async {
    await open(tester);
    await tick(tester, 2);
    eof();
    await tester.pump();
    await tick(tester, 35);
    room.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await tick(tester, 30);
    expect(room.mediaErrorRetryCount, 0);
    expect(native.opened, hasLength(2));
    await close(tester);
  });

  testWidgets(
      'five-minute failures change CDN after healthy retry resets and preserve quality',
      (tester) async {
    site.lines = ['a', 'b', 'c'];
    await open(tester);
    await tick(tester, 301);
    eof();
    await tester.pump();
    expect(native.opened.last, startsWith('https://a.invalid/'));
    await tick(tester, 301);
    expect(room.mediaErrorRetryCount, 0);
    site.lines = ['c', 'a', 'b'];
    eof();
    await tester.pump();
    expect(native.opened.last, startsWith('https://b.invalid/'));
    await tick(tester, 301);
    eof();
    await tester.pump();
    expect(native.opened.last, startsWith('https://b.invalid/'));
    await tick(tester, 301);
    eof();
    await tester.pump();
    // a is still penalized despite several healthy minutes on b.
    expect(native.opened.last, startsWith('https://c.invalid/'));
    expect(room.currentQualityInfo.value, '原画');
    expect(native.opened, hasLength(5));
    await tick(tester, 16 * 60);
    expect(native.opened, hasLength(5));
    expect(room.mediaErrorRetryCount, 0);
    await close(tester);
  });

  testWidgets('playback reload avoids recently recurring failed lines',
      (tester) async {
    await open(tester);
    for (var cycle = 0; cycle < 2; cycle++) {
      await tick(tester, 301);
      eof();
      await tester.pump();
    }
    expect(native.opened.last, startsWith('https://b.invalid/'));
    await room.getPlayUrl();
    await tester.pump();
    expect(native.opened.last, startsWith('https://b.invalid/'));
    await tick(tester, 301);
    eof();
    await tester.pump();
    expect(native.opened.last, startsWith('https://b.invalid/'));
    expect(native.opened, hasLength(5));
    await close(tester);
  });

  testWidgets('a single periodically failing CDN still gets fresh signed URLs',
      (tester) async {
    site.lines = ['a'];
    await open(tester);
    final opened = native.opened.single;
    for (var cycle = 0; cycle < 3; cycle++) {
      await tick(tester, 301);
      eof();
      await tester.pump();
    }
    expect(native.opened, hasLength(4));
    expect(native.opened.toSet(), hasLength(4));
    expect(native.opened.last, isNot(opened));
    expect(room.liveStatus.value, isTrue);
    await close(tester);
  });

  testWidgets('closing during retry backoff cancels the pending source open',
      (tester) async {
    await open(tester);
    await tick(tester, 2);
    eof();
    await tester.pump();
    await tick(tester, 2);
    eof();
    await tester.pump();
    await close(tester);
    await tester.pump(const Duration(seconds: 10));
    expect(native.opened, hasLength(2));
  });
  testWidgets(
      'decoder failure changes CDN immediately without lowering quality',
      (tester) async {
    await open(tester);
    await tick(tester, 11, decoderErrors: 15);
    expect(native.opened, hasLength(2));
    expect(native.opened.last, startsWith('https://b.invalid/'));
    expect(room.currentQualityInfo.value, '原画');
    await tick(tester, 120);
    expect(native.opened, hasLength(2));
    await close(tester);
  });

  for (final measured in <double?>[null, 0.1, 8]) {
    testWidgets('timestamp reset requires sustained measured desync: $measured',
        (tester) async {
      await open(tester);
      room.avSync = measured;
      room.handlePlayerLog(const PlayerLog(
          prefix: 'cplayer',
          level: 'warn',
          text: 'Reset playback due to audio timestamp reset.'));
      await tick(tester, 11);
      expect(native.opened, hasLength(measured == 8 ? 2 : 1));
      if (measured == 8) {
        expect(native.opened.last, startsWith('https://b.invalid/'));
        expect(room.currentQualityInfo.value, '原画');
      }
      await close(tester);
    });
  }

  testWidgets('brief desync and paused playback do not reopen', (tester) async {
    await open(tester);
    room.avSync = 8;
    room.mediaTimelineError();
    await tick(tester, 4);
    room.avSync = 0.1;
    await tick(tester, 15);
    expect(native.opened, hasLength(1));
    native.state = native.state.copyWith(playing: false);
    room.avSync = 8;
    room.mediaTimelineError();
    await tick(tester, 15, advancing: false);
    expect(native.opened, hasLength(1));
    await close(tester);
  });

  testWidgets('transient provider outage recovers without a connectivity event',
      (tester) async {
    await open(tester);
    await tick(tester, 2);
    site.failFetch = true;
    eof();
    await tester.pump();
    await tick(tester, 10, advancing: false);
    expect(native.opened, hasLength(1));
    expect(site.statusCalls, 1);
    site.failFetch = false;
    await tick(tester, 31, advancing: false);
    expect(native.opened, hasLength(2));
    expect(native.opened.last, contains('v=2'));
    expect(room.liveStatus.value, isTrue);
    expect(room.errorMsg.value, isEmpty);
    await tick(tester, 180);
    expect(native.opened, hasLength(2));
    await close(tester);
  });

  testWidgets('unknown status backs off without reopening an expired source',
      (tester) async {
    await open(tester);
    await tick(tester, 2);
    site.failFetch = true;
    site.live = null;
    eof();
    await tester.pump();
    await tick(tester, 10, advancing: false);
    expect(site.statusCalls, 1);
    await tick(tester, 31, advancing: false);
    expect(site.statusCalls, 2);
    await tick(tester, 60, advancing: false);
    expect(site.statusCalls, 3);
    expect(native.opened, hasLength(1));
    expect(room.liveStatus.value, isTrue);
    await close(tester);
    await tester.pump(const Duration(minutes: 5));
    expect(site.statusCalls, 3);
  });

  testWidgets('smooth fallback also refreshes room data before opening',
      (tester) async {
    site.qualityNames = ['原画', '高清'];
    await open(tester);
    room.smoothPlayback.value = true;
    await tick(tester, 2);
    site.rejectedQuality = '原画';
    eof();
    await tester.pump();
    await tick(tester, 10, advancing: false);
    expect(native.opened, hasLength(2));
    expect(native.opened.last, contains('v=5'));
    expect(room.currentQualityInfo.value, '高清');
    expect(room.errorMsg.value, isEmpty);
    await tick(tester, 120);
    expect(native.opened, hasLength(2));
    await close(tester);
  });

  testWidgets('failed smooth fallback retains delayed recovery',
      (tester) async {
    site.qualityNames = ['原画', '高清'];
    await open(tester);
    room.smoothPlayback.value = true;
    await tick(tester, 2);
    site.failFetch = true;
    eof();
    await tester.pump();
    await tick(tester, 10, advancing: false);
    expect(native.opened, hasLength(1));
    expect(room.errorMsg.value, contains('自动重试'));
    site.failFetch = false;
    await tick(tester, 31, advancing: false);
    expect(native.opened, hasLength(2));
    expect(native.opened.last, contains('v=2'));
    expect(room.currentQualityInfo.value, '原画');
    expect(room.errorMsg.value, isEmpty);
    await close(tester);
  });

  testWidgets(
      'quality fallback consults history for the newly selected quality',
      (tester) async {
    site.qualityNames = ['原画', '高清'];
    await open(tester);
    room.currentQuality = 1;
    await room.getPlayUrl();
    await room.changePlayLine(1);
    await tick(tester, 2, advancing: false);
    room.mediaError('tcp: Failed to resolve hostname b.invalid');
    await tick(tester, 1, advancing: false);
    expect(native.opened.last, startsWith('https://a.invalid/'));
    await room.changePlayLine(0);
    room.currentQuality = 0;
    await room.getPlayUrl();
    room.smoothPlayback.value = true;
    await tick(tester, 2);
    site.rejectedQuality = '原画';
    eof();
    await tester.pump();
    await tick(tester, 10, advancing: false);
    expect(room.currentQualityInfo.value, '高清');
    expect(native.opened.last, startsWith('https://a.invalid/'));
    await close(tester);
  });

  testWidgets('confirmed offline cancels slow retries', (tester) async {
    await open(tester);
    await tick(tester, 2);
    site.failFetch = true;
    site.live = false;
    eof();
    await tester.pump();
    await tick(tester, 300, advancing: false);
    expect(native.opened, hasLength(1));
    expect(site.statusCalls, 1);
    expect(room.liveStatus.value, isFalse);
    await close(tester);
  });

  testWidgets('background suspends failed-source probes and resume re-arms one',
      (tester) async {
    await open(tester);
    await tick(tester, 2);
    site.failFetch = true;
    eof();
    await tester.pump();
    await tick(tester, 10, advancing: false);
    room.didChangeAppLifecycleState(AppLifecycleState.paused);
    await tick(tester, 120, advancing: false);
    expect(site.statusCalls, 1);
    site.failFetch = false;
    room.didChangeAppLifecycleState(AppLifecycleState.resumed);
    room.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await tick(tester, 31, advancing: false);
    expect(native.opened, hasLength(2));
    expect(site.statusCalls, 2);
    await close(tester);
  });
  void dnsFailure() => room.mediaError(
      'tcp: Failed to resolve hostname a.invalid: Temporary failure in name resolution');

  testWidgets('DNS failure on the first open switches without startup grace',
      (tester) async {
    native.duringOpen = dnsFailure;
    await open(tester);
    native.state = native.state.copyWith(buffering: true);
    await tick(tester, 1, advancing: false);
    expect(native.opened, hasLength(2));
    expect(native.opened.last, startsWith('https://b.invalid/'));
    await close(tester);
  });

  testWidgets('same-host DNS from the old stream allows new-stream startup',
      (tester) async {
    await open(tester);
    await tick(tester, 2);
    native.duringOpen = dnsFailure;
    eof();
    await tester.pump();
    native.state = native.state.copyWith(buffering: true);
    await tick(tester, 2, advancing: false);
    expect(native.opened, hasLength(2));
    native.state = native.state.copyWith(buffering: false);
    await tick(tester, 15);
    expect(native.opened, hasLength(2));
    await close(tester);
  });

  testWidgets(
      'DNS failure bypasses twelve-second buffer grace and duplicate errors',
      (tester) async {
    await open(tester);
    await tick(tester, 2, advancing: false);
    native.state = native.state.copyWith(buffering: true);
    dnsFailure();
    room.mediaError('Failed to open https://a.invalid/live.flv');
    await tick(tester, 1, advancing: false);
    expect(native.opened, hasLength(2));
    expect(native.opened.last, startsWith('https://b.invalid/'));
    expect(room.currentQualityInfo.value, '原画');
    await tick(tester, 65);
    expect(native.opened, hasLength(2));
    await close(tester);
  });

  testWidgets(
      'DNS history survives reload and leaving then reentering the room',
      (tester) async {
    await open(tester);
    await tick(tester, 2, advancing: false);
    dnsFailure();
    await tick(tester, 1, advancing: false);
    await room.getPlayUrl();
    expect(native.opened.last, startsWith('https://b.invalid/'));
    await close(tester);
    native = _Player();
    await open(tester);
    expect(native.opened.single, startsWith('https://b.invalid/'));
    await close(tester);
  });

  testWidgets('an explicit line selection overrides avoidance once',
      (tester) async {
    await open(tester);
    await tick(tester, 2, advancing: false);
    dnsFailure();
    await tick(tester, 1, advancing: false);
    expect(native.opened.last, startsWith('https://b.invalid/'));
    await room.changePlayLine(0);
    expect(native.opened.last, startsWith('https://a.invalid/'));
    await tick(tester, 2, advancing: false);
    dnsFailure();
    await tick(tester, 1, advancing: false);
    expect(native.opened.last, startsWith('https://b.invalid/'));
    await close(tester);
  });

  testWidgets(
      'late errors from the previous hostname do not reopen the good source',
      (tester) async {
    await open(tester);
    await tick(tester, 2, advancing: false);
    dnsFailure();
    await tick(tester, 1, advancing: false);
    dnsFailure();
    room.mediaError('Failed to open https://a.invalid/old.flv');
    await tick(tester, 20);
    expect(native.opened, hasLength(2));
    await close(tester);
  });

  testWidgets('an advancing source ignores delayed same-host DNS errors',
      (tester) async {
    await open(tester);
    await tick(tester, 2);
    dnsFailure();
    await tick(tester, 5);
    expect(native.opened, hasLength(1));
    await close(tester);
  });

  testWidgets('DNS errors do not override user pause or background state',
      (tester) async {
    await open(tester);
    await tick(tester, 2);
    native.state = native.state.copyWith(playing: false);
    dnsFailure();
    await tick(tester, 2, advancing: false);
    expect(native.opened, hasLength(1));
    native.state = native.state.copyWith(playing: true);
    dnsFailure();
    room.didChangeAppLifecycleState(AppLifecycleState.paused);
    await tick(tester, 20, advancing: false);
    expect(native.opened, hasLength(1));
    await close(tester);
  });

  testWidgets('recovery fetches have a total deadline and discard late results',
      (tester) async {
    await open(tester);
    await tick(tester, 2);
    final gate = Completer<void>();
    site.roomGate = gate;
    eof();
    await tester.pump();
    await tick(tester, 13, advancing: false);
    expect(native.opened, hasLength(1));
    expect(site.statusCalls, 1);
    expect(site.scopes, isNotEmpty);
    expect(site.scopes.every((scope) => !scope.active), isTrue);
    site.roomGate = null;
    gate.complete();
    await tester.pump();
    expect(native.opened, hasLength(1));
    await tick(tester, 31, advancing: false);
    expect(native.opened, hasLength(2));
    await close(tester);
  });

  testWidgets(
      'closing during provider fetch cancels its scope and prevents late open',
      (tester) async {
    await open(tester);
    await tick(tester, 2);
    final gate = Completer<void>();
    site.roomGate = gate;
    eof();
    await tester.pump();
    expect(site.scopes.last.active, isTrue);
    await close(tester);
    expect(site.scopes.last.active, isFalse);
    site.roomGate = null;
    gate.complete();
    await tester.pump(const Duration(seconds: 30));
    expect(native.opened, hasLength(1));
  });

  testWidgets(
      'healthy playback remains one source for over two simulated hours',
      (tester) async {
    await open(tester);
    await tick(tester, 2 * 60 * 60 + 10);
    expect(native.opened, hasLength(1));
    expect(room.currentQualityInfo.value, '原画');
    expect(room.mediaErrorRetryCount, 0);
    await close(tester);
  });

  testWidgets('closing also cancels initial quality discovery', (tester) async {
    await open(tester);
    final gate = Completer<void>();
    site.qualityGate = gate;
    final request = room.getPlayQualites();
    await tester.pump();
    final scope = site.scopes.last;
    expect(scope.active, isTrue);
    await close(tester);
    await request;
    expect(scope.active, isFalse);
    gate.complete();
    await tester.pump();
    expect(native.opened, hasLength(1));
  });
  testWidgets('EOF received in background resumes recovery on foreground',
      (tester) async {
    await open(tester);
    await tick(tester, 2);
    room.didChangeAppLifecycleState(AppLifecycleState.paused);
    eof();
    await tick(tester, 20, advancing: false);
    expect(native.opened, hasLength(1));
    room.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await tick(tester, 4, advancing: false);
    expect(native.opened, hasLength(2));
    await close(tester);
  });

  testWidgets(
      'background cancels recovery fetch and resume requests fresh data',
      (tester) async {
    await open(tester);
    await tick(tester, 2);
    final gate = Completer<void>();
    site.roomGate = gate;
    eof();
    await tester.pump();
    final pending = site.scopes.last;
    room.didChangeAppLifecycleState(AppLifecycleState.paused);
    await tester.pump();
    expect(pending.active, isFalse);
    site.roomGate = null;
    gate.complete();
    await tick(tester, 20, advancing: false);
    expect(native.opened, hasLength(1));
    room.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await tick(tester, 4, advancing: false);
    expect(native.opened, hasLength(2));
    await close(tester);
  });
  testWidgets('retry backoff cannot extend the twelve-second fetch budget',
      (tester) async {
    site.lines = ['a', 'b', 'c', 'd'];
    await open(tester);
    await tick(tester, 2);
    site.failFetch = true;
    eof();
    await tester.pump();
    await tick(tester, 12, advancing: false);
    expect(site.statusCalls, 1);
    expect(native.opened, hasLength(1));
    expect(room.liveStatus.value, isTrue);
    await close(tester);
  });
  testWidgets(
      'old terminal errors during open do not interrupt a new stream starting up',
      (tester) async {
    native.duringOpen = () => room.mediaError('http: HTTP error 404 Not Found');
    await open(tester);
    native.state = native.state.copyWith(buffering: true);
    await tick(tester, 2, advancing: false);
    expect(native.opened, hasLength(1));
    native.state = native.state.copyWith(buffering: false);
    await tick(tester, 15);
    expect(native.opened, hasLength(1));
    await close(tester);
  });
}
