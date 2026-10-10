import 'package:dio/dio.dart';

class ParsedRoom {
  final String siteId;
  final String roomId;
  const ParsedRoom(this.siteId, this.roomId);
}

/// Shared by search and the existing link tools. Redirects are resolved only
/// for official short-link hosts, with a limit to prevent redirect loops.
class RoomInputParser {
  static Future<ParsedRoom?> parse(String input,
      {Dio? client, int depth = 0}) async {
    if (depth > 4) return null;
    final match = RegExp(r'https?://[^\s<>"，。]+').firstMatch(input);
    final uri = Uri.tryParse(match?.group(0) ?? input.trim());
    if (uri == null ||
        !['http', 'https'].contains(uri.scheme) ||
        uri.userInfo.isNotEmpty) {
      return null;
    }
    final host = uri.host.toLowerCase();
    final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
    if (host == 'b23.tv' || host == 'v.douyin.com') {
      final dio = client ??
          Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 8),
              receiveTimeout: const Duration(seconds: 8)));
      try {
        final response = await dio.getUri(uri,
            options: Options(
                followRedirects: false,
                validateStatus: (code) => code != null && code < 400));
        final location = response.headers.value('location');
        return location == null
            ? null
            : await parse(uri.resolve(location).toString(),
                client: dio, depth: depth + 1);
      } finally {
        if (client == null) dio.close();
      }
    }
    String? siteId;
    String? id;
    if (['live.bilibili.com', 'www.bilibili.com', 'bilibili.com']
        .contains(host)) {
      siteId = 'bilibili';
      id = segments.firstOrNull;
      if (id == null || !RegExp(r'^\d+$').hasMatch(id)) return null;
    } else if (['www.douyu.com', 'm.douyu.com', 'douyu.com'].contains(host)) {
      siteId = 'douyu';
      id = uri.queryParameters['rid'] ?? segments.lastOrNull;
    } else if (['www.huya.com', 'm.huya.com', 'huya.com'].contains(host)) {
      siteId = 'huya';
      id = segments.lastOrNull;
    } else if (host == 'live.douyin.com') {
      siteId = 'douyin';
      id = segments.firstOrNull;
    } else if (host == 'webcast.amemv.com') {
      final index = segments.indexOf('reflow');
      if (index >= 0 && index + 1 < segments.length) {
        siteId = 'douyin';
        id = segments[index + 1];
      }
    } else if (host == 'www.douyin.com' &&
        segments.firstOrNull == 'user' &&
        segments.length == 2) {
      return ParsedRoom('douyin', 'user:${segments.last}');
    }
    if (siteId == null ||
        id == null ||
        !RegExp(r'^[a-zA-Z0-9_]+$').hasMatch(id)) {
      return null;
    }
    return ParsedRoom(siteId, id);
  }
}
