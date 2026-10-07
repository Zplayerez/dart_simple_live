import 'account/platform_account.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:simple_live_core/src/common/http_client.dart';
import 'package:simple_live_core/src/danmaku/douyu_danmaku.dart';
import 'package:simple_live_core/src/interface/live_danmaku.dart';
import 'package:simple_live_core/src/interface/live_site.dart';
import 'package:simple_live_core/src/model/live_anchor_item.dart';
import 'package:simple_live_core/src/model/live_category.dart';
import 'package:simple_live_core/src/model/live_message.dart';
import 'package:simple_live_core/src/model/live_play_url.dart';
import 'package:simple_live_core/src/model/live_room_item.dart';
import 'package:simple_live_core/src/model/live_search_result.dart';
import 'package:simple_live_core/src/model/live_room_detail.dart';
import 'package:simple_live_core/src/model/live_play_quality.dart';
import 'package:simple_live_core/src/model/live_category_result.dart';
import 'package:html_unescape/html_unescape.dart';
import 'package:simple_live_core/src/scripts/douyu_sign.dart';

class DouyuSite extends LiveSite {
  DouyuSite() : super(id: "douyu", name: "斗鱼直播");
  late final String _guestDid = generateRandomString(32);

  Map<String, String> _sessionHeaders(
    String roomId,
    LiveAccountSession? session,
  ) {
    final uri = Uri.parse('https://www.douyu.com/$roomId');
    final did = session?.deviceId ?? _guestDid;
    final cookies = <String, String>{
      if (session != null && session.permits(uri)) ...session.cookie.values,
      'dy_did': did,
      'acf_did': did,
    };
    return accountRequestHeaders(session, {
      'cookie': cookies.entries.map((e) => '${e.key}=${e.value}').join('; '),
      'referer': uri.toString(),
      'user-agent':
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36',
    });
  }

  String _sign(LiveRoomDetail detail, LiveAccountSession? session) {
    if (detail.data is _DouyuRoomData) {
      final room = detail.data as _DouyuRoomData;
      if (room.sessionVersion != (session?.version ?? 0)) {
        throw StateError('账号已更新，请刷新房间信息');
      }
      return DouyuSign.getSign(
        room.script,
        detail.roomId,
        deviceId: session?.deviceId ?? _guestDid,
      );
    }
    return detail.data
        .toString(); // Backward-compatible caller-provided detail.
  }

  @override
  LiveDanmaku getDanmaku() => DouyuDanmaku();

  @override
  Future<List<LiveCategory>> getCategores() async {
    List<LiveCategory> categories = [];
    var result = await HttpClient.instance.getJson(
      "https://m.douyu.com/api/cate/list",
    );
    var subCateList = result["data"]["cate2Info"] as List;
    for (var item in result["data"]["cate1Info"]) {
      var cate1Id = item["cate1Id"];
      var cate1Name = item["cate1Name"];
      List<LiveSubCategory> subCategories = [];
      subCateList.where((x) => x["cate1Id"] == cate1Id).forEach((element) {
        subCategories.add(
          LiveSubCategory(
            pic: element["icon"],
            id: element["cate2Id"].toString(),
            parentId: cate1Id.toString(),
            name: element["cate2Name"].toString(),
          ),
        );
      });
      categories.add(
        LiveCategory(
          id: cate1Id.toString(),
          name: cate1Name.toString(),
          children: subCategories,
        ),
      );
    }
    // 根据ID排序
    categories.sort((a, b) => int.parse(a.id).compareTo(int.parse(b.id)));

    return categories;
  }

  @override
  Future<LiveCategoryResult> getCategoryRooms(
    LiveSubCategory category, {
    int page = 1,
  }) async {
    var result = await HttpClient.instance.getJson(
      "https://www.douyu.com/gapi/rkc/directory/mixList/2_${category.id}/$page",
      queryParameters: {},
    );

    var items = <LiveRoomItem>[];
    for (var item in result['data']['rl']) {
      if (item["type"] != 1) {
        continue;
      }
      var roomItem = LiveRoomItem(
        cover: item['rs16'].toString(),
        online: item['ol'],
        roomId: item['rid'].toString(),
        title: item['rn'].toString(),
        userName: item['nn'].toString(),
      );
      items.add(roomItem);
    }
    var hasMore = page < result['data']['pgcnt'];
    return LiveCategoryResult(hasMore: hasMore, items: items);
  }

  @override
  Future<List<LivePlayQuality>> getPlayQualites({
    required LiveRoomDetail detail,
  }) async {
    final session = accountSession;
    var data = _sign(detail, session);
    data += "&cdn=&rate=-1&ver=Douyu_223061205&iar=1&ive=1&hevc=0&fa=0";
    final result = await HttpClient.instance.postJson(
      "https://www.douyu.com/lapi/live/getH5Play/${detail.roomId}",
      data: data,
      header: _sessionHeaders(detail.roomId, session),
      formUrlEncoded: true,
    );

    final playData = _playResponseData(result);
    final returnedCdns = playData['cdnsWithName'];
    final returnedQualities = playData['multirates'];
    if (returnedCdns is! List || returnedQualities is! List) {
      throw StateError('斗鱼播放信息不完整，请稍后重试');
    }
    final cdns = <String>{
      for (final item in returnedCdns)
        if (item is Map &&
            item['cdn'] is String &&
            (item['cdn'] as String).trim().isNotEmpty)
          (item['cdn'] as String).trim(),
    }.toList();

    // 如果cdn以scdn开头，将其放到最后
    cdns.sort((a, b) {
      if (a.startsWith("scdn") && !b.startsWith("scdn")) {
        return 1;
      } else if (!a.startsWith("scdn") && b.startsWith("scdn")) {
        return -1;
      }
      return 0;
    });

    final qualities = <LivePlayQuality>[];
    for (final item in returnedQualities) {
      if (item is! Map) continue;
      final name = item['name'];
      final rate = int.tryParse(item['rate'].toString());
      if (name is! String || name.trim().isEmpty || rate == null || rate < 0) {
        continue;
      }
      qualities.add(
        LivePlayQuality(quality: name.trim(), data: DouyuPlayData(rate, cdns)),
      );
    }
    if (cdns.isEmpty || qualities.isEmpty) {
      throw StateError('斗鱼暂时没有可用画质或线路，请稍后重试');
    }
    return qualities;
  }

  // Dio may return text when the provider sends JSON with a non-JSON content
  // type. Never include provider bodies/messages in errors: they can contain
  // session data or a verification page. An API failure does not mean offline.
  Map _playResponseData(dynamic response) {
    if (response is String) {
      try {
        response = jsonDecode(response);
      } on FormatException {
        throw StateError('斗鱼播放接口返回了非 JSON 数据，请稍后重试');
      }
    }
    if (response is! Map) {
      throw StateError('斗鱼播放接口返回格式异常，请稍后重试');
    }
    final code = int.tryParse(response['error'].toString());
    if (code != 0) {
      throw StateError(
        code == null ? '斗鱼播放接口缺少状态码，请稍后重试' : '斗鱼暂时无法提供播放信息（错误码 $code），请稍后重试',
      );
    }
    final data = response['data'];
    if (data is! Map) {
      throw StateError('斗鱼播放接口返回的数据格式异常，请稍后重试');
    }
    return data;
  }

  @override
  Future<LivePlayUrl> getPlayUrls({
    required LiveRoomDetail detail,
    required LivePlayQuality quality,
  }) async {
    final session = accountSession;
    final args = _sign(detail, session);
    final data = quality.data as DouyuPlayData;
    final urls = <String>[];
    final metadata = <String, LivePlayUrlInfo>{};
    // A failed/slow alternative must not discard another CDN's usable source.
    // Bound fan-out and preserve the provider's order, regardless of completion.
    final results = <(String, LivePlayUrlInfo)?>[];
    final cdns = data.cdns.toSet().toList();
    for (var offset = 0; offset < cdns.length; offset += 3) {
      results.addAll(
        await Future.wait(
          cdns.skip(offset).take(3).map((cdn) async {
            try {
              return await _getPlayUrlResult(
                detail.roomId,
                args,
                data.rate,
                cdn,
                session,
              ).timeout(const Duration(seconds: 6));
            } catch (_) {
              return null;
            }
          }),
        ),
      );
    }
    for (final result in results) {
      if (result == null) continue;
      final url = result.$1;
      if (url.isNotEmpty) {
        if (!urls.contains(url)) urls.add(url);
        metadata[url] = result.$2;
      }
    }
    if (urls.isEmpty) throw StateError('斗鱼线路暂时不可用，请稍后重试');
    final first = urls.isEmpty ? null : metadata[urls.first];
    return LivePlayUrl(
      urls: urls,
      urlInfo: metadata,
      actualQuality: first?.actualQuality,
      actualRate: first?.actualRate,
      cdn: first?.cdn,
      fetchedAt: first?.fetchedAt,
      expiresInSeconds: first?.expiresInSeconds,
      limitationReason: first?.limitationReason,
      accountSessionVersion: session?.version ?? 0,
    );
  }

  Future<String> getPlayUrl(
    String roomId,
    String args,
    int rate,
    String cdn,
  ) async {
    return (await _getPlayUrlResult(
      roomId,
      args,
      rate,
      cdn,
      accountSession,
    )).$1;
  }

  Future<(String, LivePlayUrlInfo)> _getPlayUrlResult(
    String roomId,
    String args,
    int rate,
    String cdn,
    LiveAccountSession? session,
  ) async {
    final result = await HttpClient.instance.postJson(
      'https://www.douyu.com/lapi/live/getH5Play/$roomId',
      data: '$args&cdn=${Uri.encodeQueryComponent(cdn)}&rate=$rate',
      header: _sessionHeaders(roomId, session),
      formUrlEncoded: true,
    );
    final data = _playResponseData(result);
    final actualRate = int.tryParse(data['rate'].toString());
    String? actualQuality;
    final rates = data['multirates'];
    for (final quality in rates is List ? rates : const []) {
      if (quality is Map &&
          actualRate != null &&
          int.tryParse(quality['rate'].toString()) == actualRate) {
        actualQuality = quality['name']?.toString();
        break;
      }
    }
    final base = data['rtmp_url'];
    final stream = data['rtmp_live'];
    if (base is! String ||
        stream is! String ||
        base.isEmpty ||
        stream.isEmpty) {
      throw StateError('斗鱼返回的播放地址不完整，请稍后重试');
    }
    final url = '$base/${HtmlUnescape().convert(stream)}';
    final uri = Uri.tryParse(url);
    if (uri == null ||
        !const ['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty) {
      throw StateError('斗鱼返回了无效的播放地址，请稍后重试');
    }
    return (
      url,
      LivePlayUrlInfo(
        actualRate: actualRate,
        actualQuality: actualQuality,
        cdn: data['cdn']?.toString() ?? cdn,
        fetchedAt: DateTime.now(),
        expiresInSeconds: int.tryParse(data['expire'].toString()),
      ),
    );
  }

  @override
  Future<LiveCategoryResult> getRecommendRooms({int page = 1}) async {
    var result = await HttpClient.instance.getJson(
      "https://www.douyu.com/japi/weblist/apinc/allpage/6/$page",
      queryParameters: {},
    );

    var items = <LiveRoomItem>[];
    for (var item in result['data']['rl']) {
      if (item["type"] != 1) {
        continue;
      }
      var roomItem = LiveRoomItem(
        cover: item['rs16'].toString(),
        online: item['ol'],
        roomId: item['rid'].toString(),
        title: item['rn'].toString(),
        userName: item['nn'].toString(),
      );
      items.add(roomItem);
    }
    var hasMore = page < result['data']['pgcnt'];
    return LiveCategoryResult(hasMore: hasMore, items: items);
  }

  @override
  Future<LiveRoomDetail> getRoomDetail({required String roomId}) async {
    final session = accountSession;
    Map roomInfo = await _getRoomInfo(roomId, session: session);

    Map h5RoomInfo = await HttpClient.instance.getJson(
      "https://www.douyu.com/swf_api/h5room/$roomId",
      queryParameters: {},
      header: _sessionHeaders(roomId, session),
    );
    String? showTime = h5RoomInfo["data"]?["show_time"]?.toString();

    var jsEncResult = await HttpClient.instance.getText(
      "https://www.douyu.com/swf_api/homeH5Enc?rids=$roomId",
      queryParameters: {},
      header: _sessionHeaders(roomId, session),
    );
    var crptext = json.decode(jsEncResult)["data"]["room$roomId"].toString();

    if (showTime != null && showTime.isNotEmpty) {
      try {
        int startTimeStamp = int.parse(showTime);
        int currentTimeStamp = DateTime.now().millisecondsSinceEpoch ~/ 1000;
        int durationInSeconds = currentTimeStamp - startTimeStamp;

        int hours = durationInSeconds ~/ 3600;
        int minutes = (durationInSeconds % 3600) ~/ 60;
        int seconds = durationInSeconds % 60;

        String formattedDuration =
            '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
        print('斗鱼直播间 $roomId 开播时长: $formattedDuration');
      } catch (e) {
        print('计算开播时长出错: $e');
      }
    }

    return LiveRoomDetail(
      cover: roomInfo["room_pic"].toString(),
      online: int.tryParse(roomInfo["room_biz_all"]["hot"].toString()) ?? 0,
      roomId: roomInfo["room_id"].toString(),
      title: roomInfo["room_name"].toString(),
      userName: roomInfo["owner_name"].toString(),
      userAvatar: roomInfo["owner_avatar"].toString(),
      introduction: roomInfo["show_details"].toString(),
      notice: "",
      status: roomInfo["show_status"] == 1 && roomInfo["videoLoop"] != 1,
      danmakuData: roomInfo["room_id"].toString(),
      data: _DouyuRoomData(crptext, session?.version ?? 0),
      accountSessionVersion: session?.version ?? 0,
      url: "https://www.douyu.com/$roomId",
      isRecord: roomInfo["videoLoop"] == 1,
      showTime: showTime,
    );
  }

  @override
  Future<LiveSearchRoomResult> searchRooms(
    String keyword, {
    int page = 1,
  }) async {
    final session = accountSession;
    var result = await HttpClient.instance.getJson(
      "https://www.douyu.com/japi/search/api/searchShow",
      queryParameters: {"kw": keyword, "page": page, "pageSize": 20},
      header: _sessionHeaders('search/', session),
    );
    if (result['error'] != 0) {
      throw Exception(result['msg']);
    }
    var items = <LiveRoomItem>[];
    for (var item in result["data"]["relateShow"]) {
      var roomItem = LiveRoomItem(
        roomId: item["rid"].toString(),
        title: item["roomName"].toString(),
        cover: item["roomSrc"].toString(),
        userName: item["nickName"].toString(),
        online: parseHotNum(item["hot"].toString()),
      );
      items.add(roomItem);
    }
    var hasMore = result["data"]["relateShow"].isNotEmpty;
    return LiveSearchRoomResult(hasMore: hasMore, items: items);
  }

  Future<Map> _getRoomInfo(String roomId, {LiveAccountSession? session}) async {
    var result = await HttpClient.instance.getJson(
      "https://www.douyu.com/betard/$roomId",
      queryParameters: {},
      header: _sessionHeaders(roomId, session),
    );
    Map roomInfo;
    if (result is String) {
      roomInfo = json.decode(result)["room"];
    } else {
      roomInfo = result["room"];
    }
    return roomInfo;
  }

  //生成指定长度的16进制随机字符串
  String generateRandomString(int length) {
    var random = Random.secure();
    var values = List<int>.generate(length, (i) => random.nextInt(16));
    StringBuffer stringBuffer = StringBuffer();
    for (var item in values) {
      stringBuffer.write(item.toRadixString(16));
    }
    return stringBuffer.toString();
  }

  @override
  Future<LiveSearchAnchorResult> searchAnchors(
    String keyword, {
    int page = 1,
  }) async {
    final session = accountSession;
    var result = await HttpClient.instance.getJson(
      "https://www.douyu.com/japi/search/api/searchUser",
      queryParameters: {
        "kw": keyword,
        "page": page,
        "pageSize": 20,
        "filterType": 1,
      },
      header: _sessionHeaders('search/', session),
    );

    var items = <LiveAnchorItem>[];
    for (var item in result["data"]["relateUser"]) {
      var liveStatus =
          (int.tryParse(item["anchorInfo"]["isLive"].toString()) ?? 0) == 1;
      var roomType =
          (int.tryParse(item["anchorInfo"]["roomType"].toString()) ?? 0);
      var roomItem = LiveAnchorItem(
        roomId: item["anchorInfo"]["rid"].toString(),
        avatar: item["anchorInfo"]["avatar"].toString(),
        userName: item["anchorInfo"]["nickName"].toString(),
        liveStatus: liveStatus && roomType == 0,
      );
      items.add(roomItem);
    }
    var hasMore = result["data"]["relateUser"].isNotEmpty;
    return LiveSearchAnchorResult(hasMore: hasMore, items: items);
  }

  @override
  Future<bool> getLiveStatus({required String roomId}) async {
    var roomInfo = await _getRoomInfo(roomId, session: accountSession);
    return roomInfo["show_status"] == 1 && roomInfo["videoLoop"] != 1;
  }

  int parseHotNum(String hn) {
    try {
      var num = double.parse(hn.replaceAll("万", ""));
      if (hn.contains("万")) {
        num *= 10000;
      }
      return num.round();
    } catch (_) {
      return -999;
    }
  }

  @override
  Future<List<LiveSuperChatMessage>> getSuperChatMessage({
    required String roomId,
  }) {
    //尚不支持
    return Future.value([]);
  }
}

class DouyuPlayData {
  final int rate;
  final List<String> cdns;
  DouyuPlayData(this.rate, this.cdns);
}

class _DouyuRoomData {
  final String script;
  final int sessionVersion;
  const _DouyuRoomData(this.script, this.sessionVersion);
  @override
  String toString() => 'DouyuRoomData([redacted])';
}
