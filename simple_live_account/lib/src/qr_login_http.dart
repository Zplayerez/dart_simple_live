import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

class QrLoginException implements Exception {
  const QrLoginException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Isolated, in-memory cookies for one QR authorization attempt.
/// A new login never sends an account already saved by the application.
class QrCookieJar {
  final _cookies =
      <
        String,
        ({
          Cookie cookie,
          String domain,
          bool hostOnly,
          String path,
          DateTime? expires,
        })
      >{};

  void accept(Uri origin, List<Cookie> cookies) {
    for (final cookie in cookies) {
      final hostOnly = cookie.domain == null || cookie.domain!.isEmpty;
      final domain = hostOnly
          ? origin.host
          : cookie.domain!.toLowerCase().replaceFirst(RegExp(r'^\.'), '');
      // Never accept cookies for another site or a top-level domain.
      if (!domain.contains('.') ||
          !(origin.host == domain || origin.host.endsWith('.$domain')))
        continue;
      final path = cookie.path?.startsWith('/') == true
          ? cookie.path!
          : origin.path.substring(0, origin.path.lastIndexOf('/') + 1);
      final key = '$domain|$path|${cookie.name}';
      final expires = cookie.maxAge == null
          ? cookie.expires
          : DateTime.now().add(Duration(seconds: cookie.maxAge!));
      if ((expires != null && !expires.isAfter(DateTime.now())) ||
          cookie.value.isEmpty) {
        _cookies.remove(key);
      } else {
        _cookies[key] = (
          cookie: cookie,
          domain: domain,
          hostOnly: hostOnly,
          path: path.isEmpty ? '/' : path,
          expires: expires,
        );
      }
    }
  }

  String header(Uri uri) {
    _cookies.removeWhere(
      (_, c) => c.expires != null && !c.expires!.isAfter(DateTime.now()),
    );
    final matches =
        _cookies.values
            .where(
              (c) =>
                  (uri.host == c.domain ||
                      (!c.hostOnly && uri.host.endsWith('.${c.domain}'))) &&
                  (uri.path == c.path ||
                      (uri.path.startsWith(c.path) &&
                          (c.path.endsWith('/') ||
                              uri.path
                                  .substring(c.path.length)
                                  .startsWith('/')))) &&
                  (!c.cookie.secure || uri.scheme == 'https'),
            )
            .toList()
          ..sort((a, b) => b.path.length.compareTo(a.path.length));
    return matches.map((c) => '${c.cookie.name}=${c.cookie.value}').join('; ');
  }

  void clear() => _cookies.clear();
}

abstract interface class QrLoginTransport {
  Future<Uint8List> request(
    Uri uri, {
    Map<String, String>? form,
    Map<String, dynamic>? jsonBody,
  });
  String cookiesFor(Uri uri);
  void close();
}

class OfficialQrHttp implements QrLoginTransport {
  OfficialQrHttp(this.siteId) {
    _client.connectionTimeout = const Duration(seconds: 12);
    _client.userAgent =
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
        'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';
  }
  final String siteId;
  final _client = HttpClient();
  final _jar = QrCookieJar();
  bool _closed = false;

  static const hosts = {
    'bilibili': {'passport.bilibili.com', 'www.bilibili.com'},
    'douyu': {'passport.douyu.com', 'www.douyu.com'},
    'huya': {'udblgn.huya.com', 'l.huya.com', 'www.huya.com'},
  };

  static bool permits(String siteId, Uri uri) =>
      uri.scheme == 'https' &&
      uri.port == 443 &&
      uri.userInfo.isEmpty &&
      (hosts[siteId]?.contains(uri.host) ?? false);

  @override
  Future<Uint8List> request(
    Uri uri, {
    Map<String, String>? form,
    Map<String, dynamic>? jsonBody,
  }) async {
    try {
      return await _request(uri, form: form, jsonBody: jsonBody).timeout(
        const Duration(seconds: 18),
        onTimeout: () {
          close();
          throw const QrLoginException('平台响应超时，请刷新二维码重试');
        },
      );
    } on QrLoginException {
      rethrow;
    } catch (_) {
      // HttpException / SocketException may contain an authorization URL.
      throw const QrLoginException('暂时无法连接登录服务，请稍后重试');
    }
  }

  Future<Uint8List> _request(
    Uri uri, {
    Map<String, String>? form,
    Map<String, dynamic>? jsonBody,
  }) async {
    for (var redirect = 0; redirect < 6; redirect++) {
      if (_closed) throw const QrLoginException('扫码登录已取消');
      if (!permits(siteId, uri)) {
        throw const QrLoginException('平台返回了无法验证的登录地址，请重新扫码');
      }
      final request = await _client.openUrl(
        form != null || jsonBody != null ? 'POST' : 'GET',
        uri,
      );
      request.followRedirects = false;
      request.headers.set(HttpHeaders.refererHeader, switch (siteId) {
        'douyu' => 'https://passport.douyu.com/',
        'huya' => 'https://www.huya.com/',
        _ => 'https://www.bilibili.com/',
      });
      final cookie = _jar.header(uri);
      if (cookie.isNotEmpty)
        request.headers.set(HttpHeaders.cookieHeader, cookie);
      if (form != null) {
        request.headers.contentType = ContentType(
          'application',
          'x-www-form-urlencoded',
        );
        request.write(Uri(queryParameters: form).query);
      } else if (jsonBody != null) {
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode(jsonBody));
      }
      final response = await request.close();
      if (_closed) throw const QrLoginException('扫码登录已取消');
      _jar.accept(uri, response.cookies);
      final body = BytesBuilder(copy: false);
      await for (final chunk in response) {
        if (body.length + chunk.length > 2 * 1024 * 1024) {
          throw const QrLoginException('登录服务返回的数据过大，请稍后重试');
        }
        body.add(chunk);
      }
      if ({301, 302, 303, 307, 308}.contains(response.statusCode)) {
        final target = response.headers.value(HttpHeaders.locationHeader);
        if (target == null) throw const QrLoginException('登录跳转无效，请重新扫码');
        uri = uri.resolve(target);
        if ({301, 302, 303}.contains(response.statusCode)) {
          form = null;
          jsonBody = null;
        }
        continue;
      }
      if (response.statusCode != 200) {
        throw QrLoginException('登录服务暂不可用（HTTP ${response.statusCode}），请稍后重试');
      }
      return body.takeBytes();
    }
    throw const QrLoginException('登录跳转次数过多，请重新扫码');
  }

  @override
  String cookiesFor(Uri uri) => _jar.header(uri);

  @override
  void close() {
    _closed = true;
    _client.close(force: true);
    _jar.clear();
  }
}
