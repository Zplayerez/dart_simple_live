import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:simple_live_core/simple_live_core.dart';

import 'qr_login_http.dart';
export 'qr_login_http.dart' show QrLoginException;

bool supportsPlatformQrLogin(String siteId) =>
    OfficialQrHttp.hosts.containsKey(siteId);

enum QrLoginStage { waiting, scanned, confirmed, expired, cancelled }

class QrLoginCode {
  const QrLoginCode({this.text, this.image, required this.expiresAt});
  final String? text;
  final Uint8List? image;
  final DateTime expiresAt;
  @override
  String toString() => 'QrLoginCode([redacted])';
}

class QrLoginResult {
  const QrLoginResult(this.stage, {this.cookie});
  final QrLoginStage stage;
  final String? cookie;
  @override
  String toString() => 'QrLoginResult(${stage.name}, [redacted])';
}

abstract interface class QrLoginSession {
  Future<QrLoginCode> generate();
  Future<QrLoginResult> poll();
  void close();
}

/// Protocols used by each platform's official web QR login SDK. All HTTP is
/// performed by the app; no embedded browser or page execution is involved.
class OfficialQrLoginSession implements QrLoginSession {
  factory OfficialQrLoginSession(String siteId, {QrLoginTransport? transport}) {
    if (!supportsPlatformQrLogin(siteId)) {
      throw const QrLoginException('该平台暂不支持独立扫码，请使用网页登录或从其他设备接收账号');
    }
    return OfficialQrLoginSession._(
      siteId,
      transport ?? OfficialQrHttp(siteId),
    );
  }
  OfficialQrLoginSession._(this.siteId, this._http);
  final String siteId;
  final QrLoginTransport _http;
  String _key = '';
  DateTime? _expiresAt;
  bool _closed = false;
  final _random = Random.secure();

  Uri _uri(String host, String path, [Map<String, String>? query]) =>
      Uri.https(host, path, query);

  Future<Map<String, dynamic>> _json(
    Uri uri, {
    Map<String, String>? form,
    Map<String, dynamic>? body,
    bool jsonp = false,
  }) async {
    final bytes = await _http.request(uri, form: form, jsonBody: body);
    if (_closed) throw const QrLoginException('扫码登录已取消');
    try {
      var text = utf8.decode(bytes).trim();
      if (jsonp) {
        final match = RegExp(
          r'^appClient_json_callback\((.*)\);?$',
          dotAll: true,
        ).firstMatch(text);
        if (match != null) text = match.group(1)!;
      }
      final value = jsonDecode(text);
      if (value is Map<String, dynamic>) return value;
    } catch (_) {
      /* A response can contain credentials: never include it in errors. */
    }
    throw const QrLoginException('登录服务返回的数据无法识别，请稍后重试');
  }

  int? _number(dynamic value) => int.tryParse('$value');
  Map<String, dynamic> _data(Map<String, dynamic> value) =>
      value['data'] is Map<String, dynamic>
      ? value['data']
      : <String, dynamic>{};
  String _string(dynamic value) => value is String ? value : '';

  Map<String, dynamic> _huyaBody(String command, Map<String, dynamic> data) => {
    'uri': command,
    'version': '2.2',
    'context': 'WB---',
    'appId': '5002',
    'lcid': '2052',
    'byPass': '3',
    'requestId': List.generate(
      16,
      (_) => _random.nextInt(16).toRadixString(16),
    ).join(),
    'data': data,
  };

  @override
  Future<QrLoginCode> generate() async {
    _key = '';
    String? text;
    Uint8List? image;
    var lifetime = 180;
    switch (siteId) {
      case 'bilibili':
        final value = await _json(
          _uri(
            'passport.bilibili.com',
            '/x/passport-login/web/qrcode/generate',
          ),
        );
        if (_number(value['code']) != 0)
          throw const QrLoginException('哔哩哔哩二维码获取失败，请重试');
        _key = _string(_data(value)['qrcode_key']);
        text = _string(_data(value)['url']);
      case 'douyu':
        final value = await _json(
          _uri('passport.douyu.com', '/scan/generateCode'),
          form: {'client_id': '1', 'isMultiAccount': '0'},
        );
        if (_number(value['error']) != 0)
          throw const QrLoginException('斗鱼二维码获取失败，请重试');
        final data = _data(value);
        _key = _string(data['code']);
        text = _string(data['url']);
        lifetime = (_number(data['expire']) ?? 300).clamp(30, 600);
      case 'huya':
        final value = await _json(
          _uri('udblgn.huya.com', '/qrLgn/getQrId'),
          body: _huyaBody('70001', {}),
        );
        if (_number(value['returnCode']) != 0)
          throw const QrLoginException('虎牙二维码获取失败，请重试');
        _key = _string(_data(value)['qrId']);
        if (_key.isNotEmpty)
          image = await _http.request(
            _uri('udblgn.huya.com', '/qrLgn/getQrImg', {'k': _key}),
          );
        lifetime = 300;
    }
    if (_closed) throw const QrLoginException('扫码登录已取消');
    if (_key.isEmpty || ((text?.isEmpty ?? true) && (image?.isEmpty ?? true))) {
      throw const QrLoginException('平台未返回有效二维码，请刷新重试');
    }
    _expiresAt = DateTime.now().add(Duration(seconds: lifetime));
    return QrLoginCode(text: text, image: image, expiresAt: _expiresAt!);
  }

  Future<void> _callback(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null || !OfficialQrHttp.permits(siteId, uri)) {
      throw const QrLoginException('平台返回了无法验证的登录地址，请重新扫码');
    }
    await _http.request(uri);
  }

  @override
  Future<QrLoginResult> poll() async {
    if (_closed || _key.isEmpty) throw const QrLoginException('请先刷新二维码');
    if (_expiresAt == null || !DateTime.now().isBefore(_expiresAt!))
      return const QrLoginResult(QrLoginStage.expired);
    var stage = QrLoginStage.waiting;
    switch (siteId) {
      case 'bilibili':
        final value = await _json(
          _uri('passport.bilibili.com', '/x/passport-login/web/qrcode/poll', {
            'qrcode_key': _key,
          }),
        );
        if (_number(value['code']) != 0)
          throw const QrLoginException('哔哩哔哩扫码验证失败，请重试');
        stage = switch (_number(_data(value)['code'])) {
          0 => QrLoginStage.confirmed,
          86090 => QrLoginStage.scanned,
          86038 => QrLoginStage.expired,
          86101 => QrLoginStage.waiting,
          _ => throw const QrLoginException('哔哩哔哩返回未知扫码状态，请刷新重试'),
        };
      case 'douyu':
        final value = await _json(
          _uri('passport.douyu.com', '/japi/scan/auth', {
            'code': _key,
            'time': '${DateTime.now().millisecondsSinceEpoch}',
          }),
        );
        stage = switch (_number(value['error'])) {
          0 => QrLoginStage.confirmed,
          1 => QrLoginStage.scanned,
          -1 => QrLoginStage.expired,
          -2 => QrLoginStage.waiting,
          _ => throw const QrLoginException('斗鱼扫码验证失败，请刷新重试'),
        };
        if (stage == QrLoginStage.confirmed) {
          final uri = Uri.tryParse(_string(_data(value)['url']));
          if (uri == null || !OfficialQrHttp.permits(siteId, uri))
            throw const QrLoginException('斗鱼未返回有效的登录确认地址');
          final result = await _json(
            uri.replace(
              queryParameters: {
                ...uri.queryParameters,
                'callback': 'appClient_json_callback',
              },
            ),
            jsonp: true,
          );
          if (_number(result['error']) != 0)
            throw const QrLoginException('斗鱼未完成登录授权，请重新扫码');
        }
      case 'huya':
        final value = await _json(
          _uri('udblgn.huya.com', '/qrLgn/tryQrLogin'),
          body: _huyaBody('70003', {
            'qrId': _key,
            'remember': '1',
            'behavior': '',
            'page': 'https://www.huya.com/',
          }),
        );
        if (_number(value['returnCode']) != 0)
          throw const QrLoginException('虎牙扫码验证失败，请重试');
        final data = _data(value);
        stage = switch (_number(data['stage'])) {
          0 || 4 => QrLoginStage.waiting,
          1 => QrLoginStage.scanned,
          2 || 3 => QrLoginStage.confirmed,
          5 || 6 => QrLoginStage.expired,
          7 => QrLoginStage.cancelled,
          _ => throw const QrLoginException('虎牙未完成扫码授权，请重新扫码'),
        };
        if (stage == QrLoginStage.confirmed) {
          final urls = data['domainUrlList'];
          if (urls is List) {
            for (final item in urls.take(6)) {
              await _callback(
                item is Map ? _string(item['url']) : _string(item),
              );
            }
          }
          if (data['loginTime'] != null && data['sign'] is String) {
            await _callback(
              _uri('l.huya.com', '/udb_web/udbport2.php', {
                'm': 'HuyaLogin',
                'do': 'huyaCallback',
                'loginTime': '${data['loginTime']}',
                'sign': data['sign'],
              }).toString(),
            );
          }
        }
    }
    if (_closed) throw const QrLoginException('扫码登录已取消');
    if (stage != QrLoginStage.confirmed) return QrLoginResult(stage);
    final cookie = _http.cookiesFor(_uri('www.$siteId.com', '/'));
    final platform = LiveAccountPlatform.values.byName(siteId);
    if (!PlatformCookie.parse(cookie).hasAccountSessionFor(platform)) {
      throw const QrLoginException('扫码已确认，但平台未返回可用登录信息，请重新扫码');
    }
    _key = '';
    return QrLoginResult(QrLoginStage.confirmed, cookie: cookie);
  }

  @override
  void close() {
    _closed = true;
    _key = '';
    _http.close();
  }
}
