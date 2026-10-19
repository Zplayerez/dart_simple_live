import 'dart:async';
import 'dart:convert';

import 'package:simple_live_account/simple_live_account.dart';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/event_bus.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/models/db/follow_user_tag.dart';
import 'package:simple_live_app/models/db/history.dart';
import 'package:simple_live_app/services/db_service.dart';
import 'package:udp/udp.dart';
import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';
import 'package:uuid/uuid.dart';

class SyncService extends GetxService {
  static SyncService get instance => Get.find<SyncService>();

  AccountPairingHost? _accountPairing;
  int _pairingGeneration = 0;

  Future<AccountPairingReceiver> startAccountPairing(String siteId,
      Future<bool> Function() confirm, void Function(String) onStatus) async {
    if (!httpRunning.value) throw StateError('本机同步服务不可用');
    final generation = ++_pairingGeneration;
    final addresses = (await getLocalIP()).split(';');
    if (generation != _pairingGeneration) throw StateError('配对已取消');
    final address = addresses
        .firstWhere((value) => InternetAddress.tryParse(value) != null);
    _accountPairing ??= AccountPairingHost(PlatformAccountManager.instance);
    return _accountPairing!.start(
        Uri(
            scheme: 'http',
            host: address,
            port: httpPort,
            path: '/account-pairing'),
        siteId,
        confirm: confirm,
        onStatus: onStatus);
  }

  void cancelAccountPairing() {
    _pairingGeneration++;
    _accountPairing?.cancel();
  }

  Future<shelf.Response> _receivePairedAccount(shelf.Request request) async {
    final host = _accountPairing;
    if (host == null ||
        (request.contentLength ?? 0) > accountPairingMaxPayloadBytes) {
      return toJsonResponse({'status': false, 'message': '请在账号管理中打开配对页面'});
    }
    try {
      final bytes = <int>[];
      await for (final chunk
          in request.read().timeout(const Duration(seconds: 10))) {
        if (bytes.length + chunk.length > accountPairingMaxPayloadBytes) {
          return shelf.Response(413);
        }
        bytes.addAll(chunk);
      }
      return toJsonResponse(await host.receive(utf8.decode(bytes)));
    } catch (_) {
      return toJsonResponse({'status': false, 'message': '配对请求无效'});
    }
  }

  UDP? udp;
  RxList<SyncClinet> scanClients = <SyncClinet>[].obs;
  static const int udpPort = 23235;
  static const int httpPort = 23234;
  DeviceInfoPlugin deviceInfo = DeviceInfoPlugin();
  NetworkInfo networkInfo = NetworkInfo();
  HttpServer? server;
  var ipAddress = "".obs;
  var httpRunning = false.obs;
  var httpErrorMsg = "".obs;

  var deviceId = "";
  final discoveryError = ''.obs;
  final discovering = false.obs;
  Future<void>? _startingUdp;
  Future<void>? _startingServer;
  bool _closed = false;

  @override
  void onInit() {
    Log.d('TVService init');
    deviceId = (const Uuid().v4()).split('-').first;
    listenUDP();
    initServer();
    super.onInit();
  }

  /// 监听其他端UDP广播的回复
  Future<void> listenUDP() {
    if (_closed || udp != null) return Future.value();
    return _startingUdp ??= _bindUdp().whenComplete(() => _startingUdp = null);
  }

  Future<void> _bindUdp() async {
    try {
      final socket = await UDP.bind(Endpoint.any(port: const Port(udpPort)));
      if (_closed) {
        socket.close();
        return;
      }
      udp = socket;
      discoveryError.value = '';
      socket.asStream().listen(listenUdp, onError: (_) {
        if (!_closed) discoveryError.value = '设备发现暂不可用，可扫码或手动输入地址连接';
      });
    } catch (_) {
      discoveryError.value = '无法启动设备发现，可扫码或手动输入地址连接';
    }
  }

  void listenUdp(Datagram? datagram) {
    if (_closed || datagram == null || datagram.data.length > 8192) return;
    try {
      final data = jsonDecode(utf8.decode(datagram.data));
      if (data is! Map || data['id'] == deviceId) return;
      if (data['type'] == 'hello') {
        if (httpRunning.value) sendInfo();
        return;
      }
      if (data['id'] is! String ||
          data['name'] is! String ||
          data['type'] is! String) {
        return;
      }
      final address = datagram.address.address;
      final client = SyncClinet(
          id: data['id'],
          name: data['name'],
          address: address,
          port: httpPort,
          type: data['type']);
      final index =
          scanClients.indexWhere((element) => element.address == address);
      if (index < 0) {
        scanClients.add(client);
      } else {
        scanClients[index] = client;
      }
    } catch (_) {
      // Ignore unrelated or malformed broadcast packets.
    }
  }

  /// 发送UDP广播至其他端
  Future<void> sendHello() async {
    await listenUDP();
    if (_closed || udp == null) return;
    try {
      await udp!.send(
        json.encode({
          "id": deviceId,
          "type": "hello",
        }).codeUnits,
        Endpoint.broadcast(
          port: const Port(udpPort),
        ),
      );
    } catch (_) {
      discoveryError.value = '发送设备发现请求失败，可扫码或手动输入地址连接';
    }
  }

  /// UDP广播自身信息
  Future<void> sendInfo() async {
    if (_closed || udp == null) return;
    try {
      //var ip = await getLocalIP();

      var name = await getDeviceName();
      if (_closed || udp == null) return;

      var data = {
        "id": deviceId,
        "type": Platform.operatingSystem,
        //'version': Utils.packageInfo.version,
        "name": name,
        //"address": ip,
        //"port": httpPort,
      };

      await udp!.send(
        utf8.encode(json.encode(data)),
        Endpoint.broadcast(
          port: const Port(udpPort),
        ),
      );
    } catch (_) {
      discoveryError.value = '设备发现暂不可用，可扫码或手动输入地址连接';
    }
  }

  Future<String> getDeviceName() async {
    var name = "SimpleLive-${Platform.operatingSystem}";
    if (Platform.isAndroid) {
      var info = await deviceInfo.androidInfo;
      name = info.model;
    } else if (Platform.isIOS) {
      var info = await deviceInfo.iosInfo;
      name = info.name;
    } else if (Platform.isMacOS) {
      var info = await deviceInfo.macOsInfo;
      name = info.computerName;
    } else if (Platform.isLinux) {
      var info = await deviceInfo.linuxInfo;
      name = info.name;
    } else if (Platform.isWindows) {
      var info = await deviceInfo.windowsInfo;
      name = info.userName;
    }
    return name;
  }

  Future<void> refreshClients() async {
    if (_closed || discovering.value) return;
    discovering.value = true;
    scanClients.clear();
    try {
      await initServer();
      await sendHello();
      // Allow sleeping devices and a cold UDP listener to respond.
      await Future<void>.delayed(const Duration(milliseconds: 750));
      if (!_closed) await sendHello();
    } finally {
      if (!_closed) discovering.value = false;
    }
  }

  /// 读取本地IP
  /// - 如果是wifi，直接获取wifi的IP
  /// - 如果是有线，获取所有的IP，找到全部的IP
  Future<String> getLocalIP() async {
    String? ip = "";
    try {
      ip = await networkInfo.getWifiIP();
    } catch (e) {
      Log.logPrint(e);
    }
    try {
      if (ip == null || ip.isEmpty) {
        var interfaces = await NetworkInterface.list();
        var ipList = <String>[];
        for (var interface in interfaces) {
          for (var addr in interface.addresses) {
            if (addr.type.name == 'IPv4' &&
                !addr.address.startsWith('127') &&
                !addr.isMulticast &&
                !addr.isLoopback) {
              ipList.add(addr.address);
              break;
            }
          }
        }
        ip = ipList.join(';');
      }
    } catch (e) {
      Log.logPrint(e);
    }
    return ip ?? "";
  }

  /// 初始化HTTP服务
  Future<void> initServer() {
    if (_closed) return Future.value();
    return _startingServer ??=
        _initServer().whenComplete(() => _startingServer = null);
  }

  Future<void> _initServer() async {
    if (server != null) {
      ipAddress.value = await getLocalIP();
      return;
    }
    try {
      server = await shelf_io.serve(
        createHandler(),
        InternetAddress.anyIPv4,
        httpPort,
      );

      if (_closed) {
        await server!.close(force: true);
        server = null;
        return;
      }
      // Enable content compression
      server!.autoCompress = true;
      httpErrorMsg.value = '';

      httpRunning.value = true;

      var ip = await getLocalIP();
      ipAddress.value = ip;

      Log.d('Serving at http://$ip:${server!.port}');
    } catch (e) {
      httpRunning.value = server != null;
      httpErrorMsg.value = '本机同步服务启动失败，请重试并检查是否有其他应用占用端口';
      Log.w('LocalSync startup failed: ${e.runtimeType}');
    }
  }

  shelf.Handler createHandler() {
    var serverRouter = Router();
    serverRouter.post('/account-pairing', _receivePairedAccount);
    serverRouter.get('/', _helloRequest);
    serverRouter.get('/info', _infoRequest);
    serverRouter.post('/sync/follow', _syncFollowUserReuqest);
    serverRouter.post('/sync/tag', _syncFollowUserTagRequest);
    serverRouter.post('/sync/history', _syncHistoryReuqest);
    serverRouter.post('/sync/blocked_word', _syncBlockedWordReuqest);
    serverRouter.post('/sync/account/bilibili', _syncBiliAccountReuqest);

    return serverRouter.call;
  }

  /// 测试服务能否正常访问
  shelf.Response _helloRequest(shelf.Request request) {
    return toJsonResponse({
      'status': true,
      'message': 'http server is running...',
      "version":
          'SimpeLive ${Platform.operatingSystem} v${Utils.packageInfo.version}',
    });
  }

  /// 发送自己的信息
  Future<shelf.Response> _infoRequest(shelf.Request request) async {
    var name = await getDeviceName();
    return toJsonResponse({
      "id": deviceId,
      'type': Platform.operatingSystem,
      'name': name,
      'version': Utils.packageInfo.version,
      'address': ipAddress.value,
      'port': httpPort,
    });
  }

  /// 同步关注用户列表
  Future<shelf.Response> _syncFollowUserReuqest(shelf.Request request) async {
    try {
      var overlay =
          int.parse(request.requestedUri.queryParameters['overlay'] ?? '0');

      var body = await request.readAsString();
      final jsonBody = json.decode(body) as List;
      final items = jsonBody.map((item) => FollowUser.fromJson(item)).toList();
      if (overlay == 1) {
        await DBService.instance.followBox.clear();
      }
      for (final user in items) {
        await DBService.instance.followBox.put(user.id, user);
      }

      SmartDialog.showToast('已同步关注用户列表');
      EventBus.instance.emit(Constant.kUpdateFollow, 0);
      return toJsonResponse({
        'status': true,
        'message': 'success',
      });
    } catch (e) {
      return toJsonResponse({
        'status': false,
        'message': e.toString(),
      });
    }
  }

  /// 同步标签列表
  Future<shelf.Response> _syncFollowUserTagRequest(
      shelf.Request request) async {
    try {
      var overlay =
          int.parse(request.requestedUri.queryParameters['overlay'] ?? '0');

      var body = await request.readAsString();
      final jsonBody = json.decode(body) as List;
      final items =
          jsonBody.map((item) => FollowUserTag.fromJson(item)).toList();
      if (overlay == 1) {
        await DBService.instance.tagBox.clear();
      }
      for (final tag in items) {
        await DBService.instance.tagBox.put(tag.id, tag);
      }

      SmartDialog.showToast('已同步标签列表');
      EventBus.instance.emit(Constant.kUpdateFollow, 0);
      return toJsonResponse({
        'status': true,
        'message': 'success',
      });
    } catch (e) {
      return toJsonResponse({
        'status': false,
        'message': e.toString(),
      });
    }
  }

  /// 同步观看记录
  Future<shelf.Response> _syncHistoryReuqest(shelf.Request request) async {
    try {
      var overlay =
          int.parse(request.requestedUri.queryParameters['overlay'] ?? '0');
      var body = await request.readAsString();
      final jsonBody = json.decode(body) as List;
      final items = jsonBody.map((item) => History.fromJson(item)).toList();
      if (overlay == 1) {
        await DBService.instance.historyBox.clear();
      }
      for (final history in items) {
        if (DBService.instance.historyBox.containsKey(history.id)) {
          var old = DBService.instance.historyBox.get(history.id);
          //如果本地的更新时间比较新，就不更新
          if (old!.updateTime.isAfter(history.updateTime)) {
            continue;
          }
        }
        await DBService.instance.addOrUpdateHistory(history);
      }

      SmartDialog.showToast('已同步观看记录');
      EventBus.instance.emit(Constant.kUpdateHistory, 0);
      return toJsonResponse({
        'status': true,
        'message': 'success',
      });
    } catch (e) {
      return toJsonResponse({
        'status': false,
        'message': e.toString(),
      });
    }
  }

  /// 同步弹幕屏蔽词
  Future<shelf.Response> _syncBlockedWordReuqest(shelf.Request request) async {
    try {
      var overlay =
          int.parse(request.requestedUri.queryParameters['overlay'] ?? '0');
      var body = await request.readAsString();
      final jsonBody = (json.decode(body) as List).cast<String>().toList();
      if (overlay == 1) {
        AppSettingsController.instance.clearShieldList();
      }
      for (var keyword in jsonBody) {
        AppSettingsController.instance.addShieldList(keyword.trim());
      }
      SmartDialog.showToast('已同步弹幕屏蔽词');
      return toJsonResponse({
        'status': true,
        'message': 'success',
      });
    } catch (e) {
      return toJsonResponse({
        'status': false,
        'message': e.toString(),
      });
    }
  }

  /// 同步哔哩哔哩账号
  Future<shelf.Response> _syncBiliAccountReuqest(shelf.Request request) async {
    return toJsonResponse({'status': false, 'message': '请在账号管理中使用加密配对接收'});
  }

  shelf.Response toJsonResponse(Map<String, dynamic> data) {
    return shelf.Response.ok(
      json.encode(data),
      headers: {
        'Content-Type': 'application/json',
      },
      encoding: Encoding.getByName('utf-8'),
    );
  }

  @override
  void onClose() {
    _closed = true;
    cancelAccountPairing();
    Log.d('SyncService close');
    udp?.close();
    server?.close(force: true);
    super.onClose();
  }
}

class SyncClinet {
  final String id;
  final String name;
  final String address;
  final int port;
  final String type;
  SyncClinet({
    required this.id,
    required this.name,
    required this.address,
    required this.port,
    required this.type,
  });
}
