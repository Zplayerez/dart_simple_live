import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:simple_live_core/simple_live_core.dart';

const accountPairingMaxPayloadBytes = 64 * 1024;
const accountPairingMaxCookieBytes = 32 * 1024;
const accountPairingLifetime = Duration(minutes: 2);

/// A short-lived encryption capability. The QR includes its random key but
/// never a Cookie. Do not log, upload or put this invitation in ordinary backup.
class AccountPairingInvitation {
  AccountPairingInvitation._({
    required this.receiverUri,
    required this.siteId,
    required this.id,
    required this.expiresAt,
    required List<int> key,
  }) : _key = List.unmodifiable(key);

  final Uri receiverUri;
  final String siteId;
  final String id;
  final DateTime expiresAt;
  final List<int> _key;
  String? _lastRequestNonce;
  static final _cipher = AesGcm.with256bits();

  factory AccountPairingInvitation.parse(String value, {DateTime? now}) {
    try {
      if (utf8.encode(value).length > 4096) throw const FormatException();
      final data = jsonDecode(value);
      if (data is! Map<String, dynamic> ||
          data['v'] != 1 ||
          data['endpoint'] is! String ||
          data['site'] is! String ||
          data['id'] is! String ||
          data['key'] is! String ||
          data['expires'] is! int)
        throw const FormatException();
      final uri = _validateReceiver(Uri.parse(data['endpoint'] as String));
      final site = _validateSite(data['site'] as String);
      final id = data['id'] as String;
      final key = base64Url.decode(data['key'] as String);
      if (base64Url.decode(id).length != 24 || key.length != 32) {
        throw const FormatException();
      }
      final expires = DateTime.fromMillisecondsSinceEpoch(
        data['expires'] as int,
        isUtc: true,
      );
      final clock = (now ?? DateTime.now()).toUtc();
      if (!clock.isBefore(expires) ||
          expires.difference(clock) > accountPairingLifetime) {
        throw const FormatException();
      }
      return AccountPairingInvitation._(
        receiverUri: uri,
        siteId: site,
        id: id,
        expiresAt: expires,
        key: key,
      );
    } catch (_) {
      throw const FormatException('配对信息无效或已过期，请在接收端重新配对');
    }
  }

  String get qrPayload => jsonEncode({
    'v': 1,
    'endpoint': receiverUri.toString(),
    'site': siteId,
    'id': id,
    'key': base64Url.encode(_key),
    'expires': expiresAt.millisecondsSinceEpoch,
  });

  List<int> get _associatedData => utf8.encode(
    jsonEncode([
      'simple-live-account-pairing',
      1,
      id,
      siteId,
      receiverUri.toString(),
      expiresAt.millisecondsSinceEpoch,
    ]),
  );

  Future<String> encryptCookie(String cookie, {DateTime? now}) async {
    if (!(now ?? DateTime.now()).toUtc().isBefore(expiresAt)) {
      throw StateError('配对已过期，请重新配对');
    }
    final normalized = _validatedCookie(cookie, siteId);
    final box = await _cipher.encrypt(
      utf8.encode(normalized),
      secretKey: SecretKey(_key),
      aad: _associatedData,
    );
    final payload = jsonEncode({
      'v': 1,
      'id': id,
      'site': siteId,
      'nonce': base64Url.encode(box.nonce),
      'ciphertext': base64Url.encode(box.cipherText),
      'mac': base64Url.encode(box.mac.bytes),
    });
    _lastRequestNonce = base64Url.encode(box.nonce);
    if (utf8.encode(payload).length > accountPairingMaxPayloadBytes) {
      throw const FormatException('账号凭据过长，无法配对传输');
    }
    return payload;
  }

  List<int> _replyAssociatedData(String requestNonce) => [
    ..._associatedData,
    ...utf8.encode(':reply:$requestNonce'),
  ];

  /// Authenticate the receiver's result for this exact send operation. An
  /// acknowledgement can arrive after the QR expires while validation runs.
  Future<Map<String, dynamic>> decryptReply(String payload) async {
    try {
      if (utf8.encode(payload).length > 8192 || _lastRequestNonce == null) {
        throw const FormatException();
      }
      final data = jsonDecode(payload);
      if (data is! Map<String, dynamic> ||
          data['v'] != 1 ||
          data['kind'] != 'reply' ||
          data['id'] != id ||
          data['site'] != siteId ||
          data['request'] != _lastRequestNonce ||
          data['nonce'] is! String ||
          data['ciphertext'] is! String ||
          data['mac'] is! String)
        throw const FormatException();
      final nonce = base64Url.decode(data['nonce'] as String);
      final ciphertext = base64Url.decode(data['ciphertext'] as String);
      final mac = base64Url.decode(data['mac'] as String);
      if (nonce.length != 12 || mac.length != 16 || ciphertext.length > 4096) {
        throw const FormatException();
      }
      final cleartext = await _cipher.decrypt(
        SecretBox(ciphertext, nonce: nonce, mac: Mac(mac)),
        secretKey: SecretKey(_key),
        aad: _replyAssociatedData(_lastRequestNonce!),
      );
      return _validatedReply(jsonDecode(utf8.decode(cleartext)));
    } catch (_) {
      throw const FormatException('无法确认接收端结果，请在接收设备查看账号状态');
    }
  }

  @override
  String toString() => 'AccountPairingInvitation($siteId, [redacted])';
}

/// Keep this instance only while the receiver's pairing screen is open.
/// A valid authenticated payload consumes the invitation once, before the
/// caller asks the user to confirm import. Invalid input never consumes it.
class AccountPairingReceiver {
  AccountPairingReceiver._(this.invitation);

  factory AccountPairingReceiver.create({
    required Uri receiverUri,
    required String siteId,
    DateTime? now,
  }) {
    final random = Random.secure();
    List<int> bytes(int count) =>
        List.generate(count, (_) => random.nextInt(256));
    return AccountPairingReceiver._(
      AccountPairingInvitation._(
        receiverUri: _validateReceiver(receiverUri),
        siteId: _validateSite(siteId),
        id: base64Url.encode(bytes(24)),
        expiresAt: (now ?? DateTime.now()).toUtc().add(accountPairingLifetime),
        key: bytes(32),
      ),
    );
  }

  final AccountPairingInvitation invitation;
  bool _consumed = false;
  bool _busy = false;
  bool _closed = false;
  String? _acceptedRequestNonce;

  String get qrPayload => invitation.qrPayload;
  DateTime get expiresAt => invitation.expiresAt;
  bool get isConsumed => _consumed;
  bool get isClosed => _closed;

  void close() {
    _closed = true;
  }

  void _ensureActive(DateTime? now) {
    if (_closed ||
        _consumed ||
        !(now ?? DateTime.now()).toUtc().isBefore(expiresAt)) {
      throw StateError('配对已结束或已过期，请重新配对');
    }
  }

  Future<String> decrypt(String payload, {DateTime? now}) async {
    _ensureActive(now);
    if (_busy) throw StateError('正在处理一次配对请求');
    _busy = true;
    try {
      if (utf8.encode(payload).length > accountPairingMaxPayloadBytes) {
        throw const FormatException();
      }
      final data = jsonDecode(payload);
      if (data is! Map<String, dynamic> ||
          data['v'] != 1 ||
          data['id'] != invitation.id ||
          data['site'] != invitation.siteId ||
          data['nonce'] is! String ||
          data['ciphertext'] is! String ||
          data['mac'] is! String)
        throw const FormatException();
      final nonce = base64Url.decode(data['nonce'] as String);
      final ciphertext = base64Url.decode(data['ciphertext'] as String);
      final mac = base64Url.decode(data['mac'] as String);
      if (nonce.length != 12 ||
          mac.length != 16 ||
          ciphertext.length > accountPairingMaxCookieBytes) {
        throw const FormatException();
      }
      final cleartext = await AccountPairingInvitation._cipher.decrypt(
        SecretBox(ciphertext, nonce: nonce, mac: Mac(mac)),
        secretKey: SecretKey(invitation._key),
        aad: invitation._associatedData,
      );
      final cookie = _validatedCookie(
        utf8.decode(cleartext),
        invitation.siteId,
      );
      _ensureActive(now);
      _acceptedRequestNonce = data['nonce'] as String;
      _consumed = true;
      return cookie;
    } catch (_) {
      throw const FormatException('配对验证失败，请检查接收端后重新配对');
    } finally {
      _busy = false;
    }
  }

  /// No credential-bearing fields are allowed in an acknowledgement.
  Future<String> encryptReply(Map<String, dynamic> result) async {
    if (!_consumed || _acceptedRequestNonce == null) {
      throw StateError('尚未接受配对请求');
    }
    final bytes = utf8.encode(jsonEncode(_validatedReply(result)));
    if (bytes.length > 4096) throw const FormatException('配对结果过长');
    final box = await AccountPairingInvitation._cipher.encrypt(
      bytes,
      secretKey: SecretKey(invitation._key),
      aad: invitation._replyAssociatedData(_acceptedRequestNonce!),
    );
    return jsonEncode({
      'v': 1,
      'kind': 'reply',
      'id': invitation.id,
      'site': invitation.siteId,
      'request': _acceptedRequestNonce,
      'nonce': base64Url.encode(box.nonce),
      'ciphertext': base64Url.encode(box.cipherText),
      'mac': base64Url.encode(box.mac.bytes),
    });
  }

  @override
  String toString() =>
      'AccountPairingReceiver(${invitation.siteId}, [redacted])';
}

Map<String, dynamic> _validatedReply(dynamic result) {
  if (result is! Map<String, dynamic> ||
      result['status'] is! bool ||
      result['message'] is! String ||
      result.length != 2) {
    throw const FormatException('配对结果格式无效');
  }
  return {'status': result['status'], 'message': result['message']};
}

String _validatedCookie(String value, String siteId) {
  if (utf8.encode(value).length > accountPairingMaxCookieBytes) {
    throw const FormatException('账号凭据过长，无法配对传输');
  }
  final cookie = PlatformCookie.parse(
    value,
    allowBareTtwid: siteId == 'douyin',
  );
  if (cookie.isEmpty) throw const FormatException('账号凭据为空');
  if (utf8.encode(cookie.header).length > accountPairingMaxCookieBytes) {
    throw const FormatException('账号凭据过长，无法配对传输');
  }
  return cookie.header;
}

String _validateSite(String siteId) {
  if (!const ['bilibili', 'douyu', 'huya', 'douyin'].contains(siteId)) {
    throw const FormatException('配对平台无效');
  }
  return siteId;
}

Uri _validateReceiver(Uri uri) {
  final address = InternetAddress.tryParse(uri.host);
  if (uri.scheme != 'http' ||
      uri.userInfo.isNotEmpty ||
      !uri.hasPort ||
      uri.port < 1 ||
      uri.port > 65535 ||
      uri.hasQuery ||
      uri.hasFragment ||
      !const ['', '/', '/account-pairing'].contains(uri.path) ||
      address == null ||
      !_isLocal(address)) {
    throw const FormatException('接收端必须是局域网 IP 地址');
  }
  return uri.replace(path: '/account-pairing');
}

bool _isLocal(InternetAddress address) {
  final bytes = address.rawAddress;
  if (address.isLoopback || address.isLinkLocal) return true;
  if (bytes.length == 4) {
    return bytes[0] == 10 ||
        (bytes[0] == 172 && bytes[1] >= 16 && bytes[1] <= 31) ||
        (bytes[0] == 192 && bytes[1] == 168);
  }
  // IPv6 unique local addresses; no DNS resolution or public targets.
  return bytes.length == 16 && (bytes[0] & 0xfe) == 0xfc;
}
