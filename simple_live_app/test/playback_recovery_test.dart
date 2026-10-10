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

class _Settings extends AppSettingsController {
  // Storage is not part of these playback tests.
  @override
  // ignore: must_call_super
  void onInit() {}
}

class _Site extends LiveSite {
  _Site() : super(id: 'douyu');
  List<String> lines = ['a', 'b'];
  int revision = 0;
  int statusCalls = 0;
  bool failFetch = false;
  bool? live = true;

  @override
  Future<LiveRoomDetail> getRoomDetail({required String roomId}) async {
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
        url: '');
  }

  @override
  Future<List<LivePlayQuality>> getPlayQualites(
          {required LiveRoomDetail detail}) async =>
      [LivePlayQuality(quality: '原画', data: null)];

  @override
  Future<LivePlayUrl> getPlayUrls(
          {required LiveRoomDetail detail,
          required LivePlayQuality quality}) async =>
      LivePlayUrl(urls: [
        for (final line in lines) 'https://$line.invalid/live.flv?v=$revision',
      ]);

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
    Get.testMode = true;
    Log.logger = Logger(level: Level.off);
    site = _Site();
    native = _Player();
    Get.put<AppSettingsController>(_Settings());
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
    await tick(tester, 30, advancing: false);
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

  testWidgets('an explicit playback reload clears the recurring line history',
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
    expect(native.opened.last, startsWith('https://a.invalid/'));
    await tick(tester, 301);
    eof();
    await tester.pump();
    expect(native.opened.last, startsWith('https://a.invalid/'));
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
}
