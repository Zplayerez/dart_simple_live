import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:simple_live_core/simple_live_core.dart';
import 'package:simple_live_core/src/common/web_socket_util.dart';

import '../common/binary_writer.dart';

class DouyuDanmaku implements LiveDanmaku {
  @override
  int heartbeatTime = 45 * 1000;

  @override
  Function(LiveMessage msg)? onMessage;
  @override
  Function(String msg)? onClose;
  @override
  Function()? onReady;
  String serverUrl = "wss://danmuproxy.douyu.com:8506";

  WebScoketUtils? webScoketUtils;
  final _packets = _DouyuPacketDecoder();

  @override
  Future start(dynamic args) async {
    _packets.clear();
    webScoketUtils = WebScoketUtils(
      url: serverUrl,
      heartBeatTime: heartbeatTime,
      onMessage: (e) {
        decodeMessage(e);
      },
      onReady: () {
        _packets.clear();
        onReady?.call();
        joinRoom(args);
      },
      onHeartBeat: () {
        heartbeat();
      },
      onReconnect: () {
        onClose?.call("与服务器断开连接，正在尝试重连");
      },
      onClose: (e) {
        onClose?.call("服务器连接失败$e");
      },
    );
    webScoketUtils?.connect();
  }

  void joinRoom(roomId) {
    webScoketUtils?.sendMessage(
      serializeDouyu("type@=loginreq/roomid@=$roomId/"),
    );
    webScoketUtils?.sendMessage(
      serializeDouyu("type@=joingroup/rid@=$roomId/gid@=-9999/"),
    );
  }

  @override
  void heartbeat() {
    var data = serializeDouyu("type@=mrkl/");
    webScoketUtils?.sendMessage(data);
  }

  @override
  Future stop() async {
    _packets.clear();
    onMessage = null;
    onClose = null;
    webScoketUtils?.close();
  }

  void decodeMessage(List<int> data) {
    for (final body in _packets.add(data)) {
      _decodeBody(body);
    }
  }

  void _decodeBody(String result) {
    try {
      var jsonData = sttToJObject(result);
      if (jsonData is! Map) return;

      var type = jsonData["type"]?.toString();
      //斗鱼好像不会返回人气值
      if (type == "chatmsg") {
        // 屏蔽阴间弹幕
        if (jsonData["dms"] == null) {
          return;
        }
        var col = int.tryParse(jsonData["col"].toString()) ?? 0;
        var liveMsg = LiveMessage(
          type: LiveMessageType.chat,
          userName: jsonData["nn"].toString(),
          message: jsonData["txt"].toString(),
          color: getColor(col),
        );

        onMessage?.call(liveMsg);
      }
    } catch (e) {
      CoreLog.error(e);
    }
  }

  List<int> serializeDouyu(String body) {
    try {
      const int clientSendToServer = 689;
      const int encrypted = 0;
      const int reserved = 0;

      List<int> buffer = utf8.encode(body);

      var writer = BinaryWriter([]);
      writer.writeInt(4 + 4 + buffer.length + 1, 4, endian: Endian.little);
      writer.writeInt(4 + 4 + buffer.length + 1, 4, endian: Endian.little);
      writer.writeInt(clientSendToServer, 2, endian: Endian.little);
      writer.writeInt(encrypted, 1, endian: Endian.little);
      writer.writeInt(reserved, 1, endian: Endian.little);
      writer.writeBytes(buffer);
      writer.writeInt(0, 1, endian: Endian.little);
      return writer.buffer;
    } catch (e) {
      CoreLog.error(e);
      return [];
    }
  }

  String? deserializeDouyu(List<int> buffer) {
    final bodies = _DouyuPacketDecoder().add(buffer);
    return bodies.isEmpty ? null : bodies.first;
  }

  //辣鸡STT
  dynamic sttToJObject(String str) {
    if (str.contains("//")) {
      var result = [];
      for (var field in str.split("//")) {
        if (field.isEmpty) {
          continue;
        }
        result.add(sttToJObject(field));
      }
      return result;
    }
    if (str.contains("@=")) {
      var result = {};
      for (var field in str.split('/')) {
        if (field.isEmpty) {
          continue;
        }
        final delimiter = field.indexOf('@=');
        if (delimiter < 0) continue;
        var k = field.substring(0, delimiter);
        var v = unscapeSlashAt(field.substring(delimiter + 2));
        result[k] = sttToJObject(v);
      }
      return result;
    } else if (str.contains("@A=")) {
      return sttToJObject(unscapeSlashAt(str));
    } else {
      return unscapeSlashAt(str);
    }
  }

  String unscapeSlashAt(String str) {
    return str.replaceAll("@S", "/").replaceAll("@A", "@");
  }

  LiveMessageColor getColor(int type) {
    switch (type) {
      case 1:
        return LiveMessageColor(255, 0, 0);
      case 2:
        return LiveMessageColor(30, 135, 240);
      case 3:
        return LiveMessageColor(122, 200, 75);
      case 4:
        return LiveMessageColor(255, 127, 0);
      case 5:
        return LiveMessageColor(155, 57, 244);
      case 6:
        return LiveMessageColor(255, 105, 180);
      default:
        return LiveMessageColor.white;
    }
  }
}

/// WebSocket messages may contain several packets or a partial packet. Validate
/// both lengths and the header before trusting offsets; retain only a bounded
/// incomplete tail. Bad bytes cannot poison all subsequent chat packets.
class _DouyuPacketDecoder {
  static const _maxPacketLength = 1024 * 1024;
  Uint8List _pending = Uint8List(0);

  void clear() => _pending = Uint8List(0);

  List<String> add(List<int> data) {
    final bytes = Uint8List.fromList([..._pending, ...data]);
    clear();
    final view = ByteData.sublistView(bytes);
    final result = <String>[];
    var offset = 0;
    while (bytes.length - offset >= 12) {
      final length = view.getUint32(offset, Endian.little);
      final duplicate = view.getUint32(offset + 4, Endian.little);
      final type = view.getUint16(offset + 8, Endian.little);
      if (length < 9 ||
          length > _maxPacketLength ||
          length != duplicate ||
          (type != 689 && type != 690) ||
          bytes[offset + 10] != 0 ||
          bytes[offset + 11] != 0) {
        offset++;
        continue;
      }
      final end = offset + length + 4;
      if (end > bytes.length) break;
      if (bytes[end - 1] != 0) {
        offset++;
        continue;
      }
      // Replace malformed text only after a complete, valid packet is framed.
      result.add(
        utf8.decode(
          Uint8List.sublistView(bytes, offset + 12, end - 1),
          allowMalformed: true,
        ),
      );
      offset = end;
    }
    if (offset < bytes.length) {
      _pending = Uint8List.fromList(bytes.sublist(offset));
    }
    return result;
  }
}
