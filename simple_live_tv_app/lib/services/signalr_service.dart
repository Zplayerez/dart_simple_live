import 'dart:async';
import 'dart:io';

import 'package:signalr_netcore/signalr_client.dart';
import 'package:simple_live_tv_app/app/log.dart';
import 'package:simple_live_tv_app/app/utils.dart';

enum SignalRConnectionState {
  connecting,
  connected,
  disconnected,
}

class SignalRService {
  static const String kUrl = String.fromEnvironment('SYNC_SERVER_URL',
      defaultValue: 'https://sync1.nsapps.cn/sync');

  SignalRService(
      {this.connectionFactory,
      this.appVersion,
      this.requestTimeout = const Duration(seconds: 20)});
  final HubConnection Function(String url)? connectionFactory;
  final String? appVersion;
  final Duration requestTimeout;
  bool _disposed = false;

  void _setState(SignalRConnectionState value) {
    if (_disposed) return;
    state = value;
    _stateStreamController.add(value);
  }

  SignalRConnectionState state = SignalRConnectionState.connecting;

  final _stateStreamController =
      StreamController<SignalRConnectionState>.broadcast();
  Stream<SignalRConnectionState> get stateStream =>
      _stateStreamController.stream;

  final _onFavoriteStreamController =
      StreamController<(bool, String)>.broadcast();
  Stream<(bool, String)> get onFavoriteStream =>
      _onFavoriteStreamController.stream;

  final _onHistoryStreamController =
      StreamController<(bool, String)>.broadcast();
  Stream<(bool, String)> get onHistoryStream =>
      _onHistoryStreamController.stream;

  final _onShieldWordStreamController =
      StreamController<(bool, String)>.broadcast();
  Stream<(bool, String)> get onShieldWordStream =>
      _onShieldWordStreamController.stream;

  final _onBiliAccountStreamController =
      StreamController<(bool, String)>.broadcast();
  Stream<(bool, String)> get onBiliAccountStream =>
      _onBiliAccountStreamController.stream;

  final _onRoomDestroyedStreamController = StreamController<String>.broadcast();
  Stream<String> get onRoomDestroyedStream =>
      _onRoomDestroyedStreamController.stream;

  final _onRoomUserUpdatedStreamController =
      StreamController<List<RoomUser>>.broadcast();
  Stream<List<RoomUser>> get onRoomUserUpdatedStream =>
      _onRoomUserUpdatedStreamController.stream;

  HubConnection? hubConnection;
  Future<void> connect() async {
    if (_disposed) throw const RemoteSyncException('同步页面已关闭');
    await disconnect();
    _setState(SignalRConnectionState.connecting);
    final connection = connectionFactory?.call(kUrl) ??
        HubConnectionBuilder().withUrl(kUrl).build();
    hubConnection = connection;
    connection.onclose(({Exception? error}) {
      if (identical(hubConnection, connection)) {
        _setState(SignalRConnectionState.disconnected);
      }
    });
    _listen();
    try {
      await connection.start()?.timeout(requestTimeout);
      if (_disposed || !identical(hubConnection, connection)) {
        await connection.stop();
        return;
      }
      _setState(SignalRConnectionState.connected);
    } catch (error) {
      await disconnect();
      throw RemoteSyncException.fromError(error, '连接同步服务器');
    }
  }

  void _listen() {
    final connection = hubConnection;
    connection?.on("onFavoriteReceived", (args) {
      if (_disposed || !identical(hubConnection, connection)) return;
      _onFavoriteStreamController.add((args![0] as bool, args[1] as String));
    });
    connection?.on("onHistoryReceived", (args) {
      if (_disposed || !identical(hubConnection, connection)) return;
      _onHistoryStreamController.add((args![0] as bool, args[1] as String));
    });
    connection?.on("onShieldWordReceived", (args) {
      if (_disposed || !identical(hubConnection, connection)) return;
      _onShieldWordStreamController.add((args![0] as bool, args[1] as String));
    });
    connection?.on("onBiliAccountReceived", (args) {
      if (_disposed || !identical(hubConnection, connection)) return;
      _onBiliAccountStreamController.add((args![0] as bool, args[1] as String));
    });
    connection?.on("onRoomDestroyed", (args) {
      if (_disposed || !identical(hubConnection, connection)) return;
      _onRoomDestroyedStreamController.add(args![0].toString());
    });
    connection?.on("onUserUpdated", (args) {
      if (_disposed || !identical(hubConnection, connection)) return;
      var list = (args![0] as List).map((e) => RoomUser.fromObject(e)).toList();
      _onRoomUserUpdatedStreamController.add(list);
    });
  }

  Future<void> disconnect() async {
    final connection = hubConnection;
    hubConnection = null;
    try {
      await connection?.stop().timeout(const Duration(seconds: 3));
    } catch (_) {
      // Closing an unavailable server must not hide the original failure.
    }
    _setState(SignalRConnectionState.disconnected);
  }

  Future<Object?> _invoke(String method, List<Object> args) async {
    if (_disposed ||
        state != SignalRConnectionState.connected ||
        hubConnection == null) {
      throw const RemoteSyncException('连接已断开，请重新连接同步房间');
    }
    try {
      return await hubConnection!
          .invoke(method, args: args)
          .timeout(requestTimeout);
    } catch (error) {
      final failure = RemoteSyncException.fromError(error, method);
      // Do not log payloads, connection tokens or room identifiers.
      Log.w(
          'RemoteSync $method failed: ${error.runtimeType}; ${failure.message}');
      throw failure;
    }
  }

  Future<Resp<String>> createRoom() async {
    String app = "Simple Live TV";
    String platform = 'tv';
    String version = appVersion ?? Utils.packageInfo.version;
    var resp = Resp<String>.fromObject(
        await _invoke('CreateRoom', [app, platform, version]));
    if (resp.isSuccess && (resp.data == null || resp.data!.trim().isEmpty)) {
      throw const RemoteSyncException('同步服务器未返回房间号，请稍后重试');
    }
    return resp;
  }

  Future<Resp> joinRoom(String roomId) async {
    String app = "Simple Live TV";
    String platform = 'tv';
    String version = appVersion ?? Utils.packageInfo.version;
    var resp = await _invoke('JoinRoom', [roomId, app, platform, version]);
    return Resp.fromObject(resp);
  }

  Future<Resp> sendContent({
    required String roomName,
    required String action,
    required bool overlay,
    required String content,
  }) async {
    var resp = await _invoke(action, [roomName, overlay, content]);
    return Resp.fromObject(resp);
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    unawaited(disconnect());
    _stateStreamController.close();
    _onFavoriteStreamController.close();
    _onHistoryStreamController.close();
    _onShieldWordStreamController.close();
    _onBiliAccountStreamController.close();
    _onRoomDestroyedStreamController.close();
    _onRoomUserUpdatedStreamController.close();
  }
}

class Resp<T> {
  final bool isSuccess;
  final String message;
  final T? data;
  Resp(this.isSuccess, this.message, this.data);

  factory Resp.fromJson(Map<String, dynamic> json) {
    if (json['isSuccess'] is! bool ||
        (json['data'] != null && json['data'] is! T)) {
      throw const RemoteSyncException('同步服务器返回的数据格式不正确，请稍后重试');
    }
    return Resp<T>(
      json['isSuccess'],
      json['message'] is String ? json['message'] : '',
      json['data'],
    );
  }

  factory Resp.fromObject(Object? obj) {
    if (obj is Map<String, dynamic>) {
      return Resp.fromJson(obj);
    }
    throw const RemoteSyncException('同步服务器未返回有效结果，请稍后重试');
  }
}

class RoomUser {
  final String connectionId;
  final String shortId;
  final String platform;
  final String version;
  final String app;
  final bool? isCreator;

  RoomUser({
    required this.connectionId,
    required this.shortId,
    required this.platform,
    required this.version,
    required this.app,
    this.isCreator = false,
  });

  factory RoomUser.fromJson(Map<String, dynamic> json) {
    return RoomUser(
      connectionId: json['connectionId'],
      shortId: json['shortId'],
      platform: json['platform'],
      version: json['version'],
      app: json['app'],
      isCreator: json['isCreator'],
    );
  }

  factory RoomUser.fromObject(Object? obj) {
    if (obj is Map<String, dynamic>) {
      return RoomUser.fromJson(obj);
    }
    return RoomUser(
      connectionId: "",
      shortId: "",
      platform: "",
      version: "",
      app: "",
    );
  }
}

class RemoteSyncException implements Exception {
  const RemoteSyncException(this.message);
  final String message;

  factory RemoteSyncException.fromError(Object error, String operation) {
    if (error is RemoteSyncException) return error;
    if (error is TimeoutException) {
      return const RemoteSyncException('同步服务器响应超时，请稍后重试');
    }
    if (error is SocketException) {
      return const RemoteSyncException('无法连接同步服务器，请检查网络后重试');
    }
    if (error.toString().contains('error occurred invoking')) {
      return const RemoteSyncException('远程同步服务器内部错误，请稍后重试；同一网络下可使用局域网同步');
    }
    return RemoteSyncException('$operation失败，请稍后重试或使用局域网同步');
  }

  @override
  String toString() => message;
}
