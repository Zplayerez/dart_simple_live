import 'dart:io';
import 'local_sync_address.dart';

import 'package:flutter/material.dart';

import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/app/controller/base_controller.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_app/requests/sync_client_request.dart';
import 'package:simple_live_app/routes/app_navigation.dart';
import 'package:simple_live_app/routes/route_path.dart';

import 'package:simple_live_app/services/sync_service.dart';

class LocalSyncController extends BaseController {
  final String? address;
  LocalSyncController(this.address);

  @override
  void onInit() {
    SyncService.instance.refreshClients();
    Future.delayed(Duration.zero, initConnect);
    super.onInit();
  }

  void initConnect() {
    if (_closed) return;
    if (address != null && address!.isNotEmpty) {
      addressController.text = address!;
      connect();
    }
  }

  TextEditingController addressController = TextEditingController();
  SyncClientRequest request = SyncClientRequest();

  bool _connecting = false;
  bool _closed = false;

  void connect() {
    try {
      final addresses = parseLocalSyncAddresses(addressController.text);
      if (addresses.length > 1) {
        showPickerAddress(addresses.map((uri) => uri.toString()).toList());
        return;
      }
      final uri = addresses.single;
      connectClient(SyncClinet(
          id: 'manual',
          address: uri.host,
          port: uri.port,
          name: '手动输入',
          type: Platform.operatingSystem));
    } on FormatException catch (error) {
      SmartDialog.showToast(error.message);
    }
  }

  void connectClient(SyncClinet client) async {
    if (_connecting || _closed) return;
    _connecting = true;
    try {
      SmartDialog.showLoading(msg: "连接中...");
      var info = await request
          .getClientInfo(client)
          .timeout(const Duration(seconds: 8));
      if (!_closed) AppNavigator.toSyncDevice(client, info);
    } catch (e) {
      if (!_closed) {
        SmartDialog.showToast('无法连接设备，请确认两台设备在同一 Wi-Fi、均已打开 App，并允许防火墙的局域网访问');
      }
    } finally {
      _connecting = false;
      SmartDialog.dismiss();
    }
  }

  void toScanQr() async {
    var result = await Get.toNamed(RoutePath.kSyncScan);
    if (result == null || result.isEmpty) {
      return;
    }
    if (_closed) return;
    addressController.text = result as String;
    connect();
  }

  void showPickerAddress(List<String> addressList) {
    SmartDialog.showToast("扫描到多个地址，请选择一个连接");
    Utils.showBottomSheet(
      title: '请选择地址',
      child: ListView.builder(
        itemBuilder: (_, i) {
          return ListTile(
            title: Text(addressList[i]),
            onTap: () {
              Get.back();
              addressController.text = addressList[i];
              connect();
            },
          );
        },
        itemCount: addressList.length,
      ),
    );
  }

  void showInfo() async {
    await SyncService.instance.initServer();
    if (_closed) return;
    Utils.showBottomSheet(
      title: "本机信息",
      child: Column(
        children: [
          Visibility(
            visible: SyncService.instance.httpRunning.value,
            child: GestureDetector(
              onTap: () {
                Get.back();
              },
              child: QrImageView(
                data: SyncService.instance.ipAddress.value,
                version: QrVersions.auto,
                backgroundColor: Colors.white,
                padding: AppStyle.edgeInsetsA12,
                size: 200,
              ),
            ),
          ),
          AppStyle.vGap24,
          Visibility(
            visible: SyncService.instance.httpRunning.value,
            child: Text(
              '服务已启动：${SyncService.instance.ipAddress.value.split(';').map((e) => '$e:${SyncService.httpPort}').join('；')}',
              textAlign: TextAlign.center,
            ),
          ),
          Visibility(
            visible: !SyncService.instance.httpRunning.value,
            child: Text(
              'HTTP服务未启动：${SyncService.instance.httpErrorMsg}，请返回后点击刷新重试',
              textAlign: TextAlign.center,
            ),
          ),
          AppStyle.vGap12,
          Visibility(
            visible: SyncService.instance.httpRunning.value,
            child: const Text(
              "请使用其他Simple Live客户端扫描上方二维码\n建立连接后可选择需要同步的数据",
              textAlign: TextAlign.center,
            ),
          ),
        ],
      ),
    );
  }

  @override
  void onClose() {
    _closed = true;
    addressController.dispose();
    super.onClose();
  }
}
