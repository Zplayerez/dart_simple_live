import 'dart:async';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart' hide Response;
import 'package:hive/hive.dart';
import 'package:simple_live_account/simple_live_account.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/models/db/follow_user_tag.dart';
import 'package:simple_live_app/models/db/history.dart';
import 'package:simple_live_app/modules/search/search_list_controller.dart';
import 'package:simple_live_app/modules/search/search_controller.dart';
import 'package:simple_live_app/modules/search/search_page.dart';
import 'package:simple_live_app/modules/live_room/live_room_controller.dart';
import 'package:simple_live_app/services/db_service.dart';
import 'package:simple_live_app/services/follow_service.dart';
import 'package:simple_live_app/services/local_storage_service.dart';
import 'package:simple_live_app/services/playback_preferences.dart';
import 'package:simple_live_app/services/room_input_parser.dart';
import 'package:simple_live_core/simple_live_core.dart';

class SearchFixture extends LiveSite {
  SearchFixture() : super(id: 'fixture');
  final requests = <String, Completer<LiveSearchRoomResult>>{};
  @override
  Future<LiveSearchRoomResult> searchRooms(String keyword, {int page = 1}) =>
      (requests['$keyword/$page'] = Completer()).future;
}

LiveSearchRoomResult found(String title, {bool more = false}) =>
    LiveSearchRoomResult(hasMore: more, items: [
      LiveRoomItem(
          roomId: title, title: title, cover: '', userName: title, online: 0)
    ]);

class FollowFixture extends LiveSite {
  FollowFixture() : super(id: 'douyin');
  final requests = <String, Completer<LiveRoomDetail>>{};
  int statusCalls = 0;
  @override
  Future<bool> getLiveStatus({required String roomId}) async {
    statusCalls++;
    return false;
  }

  @override
  Future<LiveRoomDetail> getRoomDetail({required String roomId}) =>
      (requests[roomId] = Completer()).future;
}

class StatusOnlyFixture extends LiveSite {
  StatusOnlyFixture(this.live) : super(id: 'douyu');
  final bool live;
  int details = 0;
  @override
  Future<bool> getLiveStatus({required String roomId}) async => live;
  @override
  Future<LiveRoomDetail> getRoomDetail({required String roomId}) async {
    details++;
    throw StateError('supplementary detail unavailable');
  }
}

LiveRoomDetail detail(String id, bool live) => LiveRoomDetail(
    roomId: id,
    title: id,
    cover: '',
    userName: id,
    userAvatar: '',
    online: 0,
    status: live,
    url: '');

class PlaybackFixture extends LiveSite {
  PlaybackFixture(String id) : super(id: id);
  List<String> lines = ['a', 'b'];
  int generation = 0;
  int lifetime = 0;
  @override
  Future<LiveRoomDetail> getRoomDetail({required String roomId}) async {
    generation++;
    return detail(roomId, true);
  }

  @override
  Future<List<LivePlayQuality>> getPlayQualites(
          {required LiveRoomDetail detail}) async =>
      [
        LivePlayQuality(quality: '原画', data: [
          for (final line in lines)
            'https://$line.invalid/live.flv?v=$generation'
        ])
      ];
  @override
  Future<LivePlayUrl> getPlayUrls(
          {required LiveRoomDetail detail,
          required LivePlayQuality quality}) async =>
      LivePlayUrl(
          urls: List<String>.from(quality.data),
          expiresInSeconds: lifetime,
          fetchedAt: DateTime.now());
}

class RecordingRoomController extends LiveRoomController {
  RecordingRoomController(Site site) : super(pSite: site, pRoomId: '123');
  final opened = <String>[];
  @override
  Future<int> getQualityLevel() async => 2;
  @override
  Future<void> setPlayer() async => opened.add(playUrls[currentLineIndex]);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final originalSites = Map<String, Site>.of(Sites.allSites);
  late Directory directory;
  late DBService db;
  setUp(() async {
    Get.testMode = true;
    directory = await Directory.systemTemp.createTemp('live-experience-test-');
    Hive.init(directory.path);
    if (!Hive.isAdapterRegistered(1)) Hive.registerAdapter(FollowUserAdapter());
    if (!Hive.isAdapterRegistered(3)) {
      Hive.registerAdapter(FollowUserTagAdapter());
    }
    if (!Hive.isAdapterRegistered(2)) Hive.registerAdapter(HistoryAdapter());
    final local = LocalStorageService();
    await local.init();
    await local.settingsBox.putAll({
      LocalStorageService.kAutoUpdateFollowEnable: false,
      LocalStorageService.kLogEnable: false,
      LocalStorageService.kFirstRun: false
    });
    Get.put(local);
    Get.put(AppSettingsController());
    db = DBService();
    await db.init();
    Get.put(db);
  });
  tearDown(() async {
    Get.reset();
    await Hive.close();
    Sites.allSites
      ..clear()
      ..addAll(originalSites);
    await directory.delete(recursive: true);
  });

  test('late search success cannot overwrite a newer keyword or unlock it',
      () async {
    final fixture = SearchFixture();
    final controller = SearchListController(
        Site(id: 'fixture', name: 'test', logo: '', liveSite: fixture));
    controller.keyword = 'old';
    final old = controller.refreshData();
    controller.keyword = 'new';
    final current = controller.refreshData();
    fixture.requests['old/1']!.complete(found('old'));
    await old;
    expect(controller.loadding, isTrue);
    expect(controller.list, isEmpty);
    fixture.requests['new/1']!.complete(found('new'));
    await current;
    expect((controller.list.single as LiveRoomItem).title, 'new');
    expect(controller.canLoadMore.value, isFalse);
    await controller.loadData();
    expect(fixture.requests, hasLength(2));
  });

  test(
      'late search error and duplicate pagination leave current results intact',
      () async {
    final fixture = SearchFixture();
    final controller = SearchListController(
        Site(id: 'fixture', name: 'test', logo: '', liveSite: fixture));
    controller.keyword = 'old';
    final old = controller.refreshData();
    controller.keyword = 'new';
    final current = controller.refreshData();
    fixture.requests['new/1']!.complete(found('new', more: true));
    await current;
    fixture.requests['old/1']!.completeError(StateError('stale failure'));
    await old;
    expect(controller.pageError.value, isFalse);
    final page = controller.loadData();
    await controller.loadData();
    expect(controller.loadding, isTrue);
    fixture.requests['new/2']!.complete(found('page2'));
    await page;
    expect(controller.list.map((item) => (item as LiveRoomItem).title),
        ['new', 'page2']);
  });

  test('tag reorder survives reopening and preserves delete/update identity',
      () async {
    final first = await db.addFollowTag('游戏');
    final second = await db.addFollowTag('音乐');
    expect((await db.addFollowTag('游戏')).id, first.id);
    await db.updateFollowTagOrder([second, first]);
    await db.tagBox.close();
    await db.init();
    expect(db.getFollowTagList().map((tag) => tag.id), [second.id, first.id]);
    await db.updateFollowTag(first.copyWith(tag: '游戏台'));
    expect(db.getFollowTagList(), hasLength(2));
    await db.deleteFollowTag(first.id);
    expect(db.getFollowTagList().single.id, second.id);
  });

  test('old numeric tag keys and duplicate names repair without losing members',
      () async {
    await db.tagBox.put(0, FollowUserTag(id: 'a', tag: '游戏', userId: ['u1']));
    await db.tagBox.put(1, FollowUserTag(id: 'b', tag: '游戏', userId: ['u2']));
    await db.init();
    expect(db.tagBox.keys, ['a']);
    expect(db.tagBox.get('a')!.userId, containsAll(['u1', 'u2']));
    await db.init();
    expect(db.tagBox.keys, ['a']);
  });

  test(
      'follow refresh shares in-flight work, preserves order and marks unknown failures',
      () async {
    final fixture = FollowFixture();
    Sites.allSites['douyin'] =
        Site(id: 'douyin', name: 'test', logo: '', liveSite: fixture);
    for (final id in ['first', 'second']) {
      await db.addFollow(FollowUser(
          id: 'douyin_$id',
          roomId: id,
          siteId: 'douyin',
          userName: id,
          face: '',
          addTime: DateTime(2026)));
    }
    final service = Get.put(FollowService());
    await service.loadData(updateStatus: false);
    final pending = service.startUpdateStatus();
    final same = service.startUpdateStatus();
    expect(identical(pending, same), isTrue);
    fixture.requests['second']!.complete(detail('second', true));
    fixture.requests['first']!.completeError(StateError('network'));
    await pending;
    expect(service.followList.map((item) => item.roomId), ['first', 'second']);
    expect(service.followList.first.liveStatus.value, -1);
    expect(service.notLiveList, isEmpty);
    expect(service.liveList.single.roomId, 'second');
    expect(fixture.statusCalls, 0);
    final retry = service.startUpdateStatus(failuresOnly: true);
    fixture.requests['first']!.complete(detail('first', false));
    await retry;
    expect(service.notLiveList.single.roomId, 'first');
    await service.togglePin(service.followList.last);
    expect(service.followList.first.roomId, 'second');
    expect(LocalStorageService.instance.getValue<List>('PinnedFollows', []),
        ['douyin_second']);
  });

  test('room quality overrides platform preferences without storing URLs',
      () async {
    await PlaybackPreferences.save(
        'douyu', '1', {'quality': '原画', 'smooth': false},
        forPlatform: true);
    await PlaybackPreferences.save(
        'douyu', '2', {'quality': '高清', 'smooth': true});
    expect(PlaybackPreferences.read('douyu', '1')['quality'], '原画');
    expect(PlaybackPreferences.read('douyu', '2')['quality'], '高清');
    expect(PlaybackPreferences.read('huya', '2'), isEmpty);
  });

  for (final live in [false, true]) {
    test('lightweight follow status $live survives unavailable details',
        () async {
      final fixture = StatusOnlyFixture(live);
      Sites.allSites['douyu'] =
          Site(id: 'douyu', name: 'fixture', logo: '', liveSite: fixture);
      await db.addFollow(FollowUser(
          id: 'douyu_1',
          roomId: '1',
          siteId: 'douyu',
          userName: 'fixture',
          face: '',
          addTime: DateTime(2026)));
      final service = Get.put(FollowService());
      await service.loadData();
      expect(service.followList.single.liveStatus.value, live ? 2 : 1);
      expect(fixture.details, live ? 1 : 0);
    });
  }

  test(
      'controller switches to the chosen CDN even when refreshed lines reorder',
      () async {
    final fixture = PlaybackFixture('douyin');
    Get.put(PlatformAccountManager(sites: {'douyin': fixture}));
    final controller = RecordingRoomController(
        Site(id: 'douyin', name: 'fixture', logo: '', liveSite: fixture));
    controller.detail.value = await fixture.getRoomDetail(roomId: '123');
    controller.liveStatus.value = true;
    await controller.getPlayQualites();
    fixture.lines = ['b', 'c'];
    await controller.changePlayLine(1);
    expect(controller.currentLineIndex, 0);
    expect(controller.opened.last, 'https://b.invalid/live.flv?v=2');
    expect(PlaybackPreferences.read('douyin', '123')['line'], 'b.invalid/flv');
  });

  testWidgets(
      'expiry prefetch does not reopen healthy playback; failure consumes fresh URLs',
      (tester) async {
    final fixture = PlaybackFixture('douyu')..lifetime = 300;
    Get.put(PlatformAccountManager(sites: {'douyu': fixture}));
    final controller = RecordingRoomController(
        Site(id: 'douyu', name: 'fixture', logo: '', liveSite: fixture));
    controller.detail.value = await fixture.getRoomDetail(roomId: '123');
    controller.liveStatus.value = true;
    await controller.getPlayQualites();
    expect(controller.opened, hasLength(1));
    await tester.pump(const Duration(minutes: 5));
    await tester.pump();
    expect(fixture.generation, 2);
    expect(controller.opened, hasLength(1));
    controller.mediaError('synthetic EOF');
    await tester.pump();
    expect(controller.opened, hasLength(2));
    expect(controller.opened.last, 'https://a.invalid/live.flv?v=2');
  });

  test(
      'room parser handles shared text, topic links and rejects unsupported hosts',
      () async {
    expect(
        (await RoomInputParser.parse('来看看 https://live.douyin.com/123 分享'))!
            .roomId,
        '123');
    expect(
        (await RoomInputParser.parse(
                'https://www.douyu.com/topic/abc?rid=789'))!
            .roomId,
        '789');
    expect(
        (await RoomInputParser.parse('https://www.douyin.com/user/stable'))!
            .roomId,
        'user:stable');
    expect(
        await RoomInputParser.parse('https://live.douyin.com.fake.invalid/123'),
        isNull);
    expect(await RoomInputParser.parse('https://www.bilibili.com/video/BV123'),
        isNull);
    expect(await RoomInputParser.parse('nonsense'), isNull);
  });

  test('short-link redirect loops terminate', () async {
    var calls = 0;
    final dio = Dio()
      ..interceptors.add(InterceptorsWrapper(onRequest: (request, handler) {
        calls++;
        handler.resolve(Response(
            requestOptions: request,
            statusCode: 302,
            headers: Headers.fromMap({
              'location': ['https://v.douyin.com/loop/']
            })));
      }));
    expect(
        await RoomInputParser.parse('https://v.douyin.com/loop/', client: dio),
        isNull);
    expect(calls, 5);
    dio.close();
  });

  testWidgets(
      'aggregate search renders one platform while another is still loading',
      (tester) async {
    final fixtures = <String, SearchFixture>{};
    Sites.allSites.updateAll((id, site) => Site(
        id: id,
        name: site.name,
        logo: site.logo,
        liveSite: fixtures[id] = SearchFixture()));
    final controller = Get.put(AppSearchController());
    await tester.pumpWidget(const GetMaterialApp(home: SearchPage()));
    controller.searchController.text = '主播';
    await tester.runAsync(() async {
      await controller.doSearch();
      await LocalStorageService.instance.settingsBox.flush();
    });
    await tester.runAsync(() async {
      fixtures['bilibili']!.requests['主播/1']!.complete(found('fixture-result'));
      await pumpEventQueue();
    });
    await tester.pump();
    expect(find.text('全部平台'), findsOneWidget);
    expect(find.text('fixture-result'), findsWidgets);
    expect(controller.results(controller.sites.first).loadding, isFalse);
    await tester.runAsync(() async {
      for (final entry in fixtures.entries.where((e) => e.key != 'bilibili')) {
        entry.value.requests['主播/1']!
            .complete(LiveSearchRoomResult(hasMore: false, items: []));
      }
      await pumpEventQueue();
    });
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });
}
