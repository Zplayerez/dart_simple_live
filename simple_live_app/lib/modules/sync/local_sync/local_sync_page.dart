import 'dart:io';

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:remixicon/remixicon.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/modules/sync/local_sync/local_sync_controller.dart';
import 'package:simple_live_app/services/sync_service.dart';
import 'package:simple_live_app/widgets/settings/settings_card.dart';

class LocalSyncPage extends GetView<LocalSyncController> {
  const LocalSyncPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('局域网数据同步'),
        actions: [
          TextButton.icon(
            onPressed: controller.showInfo,
            icon: const Icon(Icons.qr_code),
            label: const Text("本机二维码"),
          ),
        ],
      ),
      body: ListView(
        padding: AppStyle.edgeInsetsA12,
        children: [
          const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Text(
                  '两台设备连接同一 Wi-Fi 并打开 Simple Live。点击下方设备即可同步，也可用另一台设备扫描“本机二维码”。')),
          Obx(() => SyncService.instance.discovering.value
              ? const LinearProgressIndicator()
              : const SizedBox.shrink()),
          Obx(() => SyncService.instance.discoveryError.value.isEmpty
              ? const SizedBox.shrink()
              : Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(SyncService.instance.discoveryError.value))),
          SettingsCard(
            child: Padding(
              padding: AppStyle.edgeInsetsA12,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: controller.addressController,
                    onSubmitted: (e) {
                      controller.connect();
                    },
                    decoration: InputDecoration(
                      labelText: '客户端地址',
                      hintText: '输入另一台设备的 IP 地址，或扫码连接',
                      contentPadding: AppStyle.edgeInsetsH12,
                      border: const OutlineInputBorder(),
                      suffixIcon: Visibility(
                        visible: Platform.isAndroid || Platform.isIOS,
                        child: TextButton.icon(
                          onPressed: controller.toScanQr,
                          icon: const Icon(Remix.qr_scan_line),
                          label: const Text("扫一扫"),
                        ),
                      ),
                    ),
                  ),
                  AppStyle.vGap12,
                  ElevatedButton(
                    onPressed: () {
                      controller.connect();
                    },
                    child: const Text("连接"),
                  ),
                ],
              ),
            ),
          ),
          AppStyle.vGap12,
          ListTile(
            title: Obx(
              () => Text(
                "已发现设备(${SyncService.instance.scanClients.length})",
                style: Get.textTheme.titleSmall,
              ),
            ),
            visualDensity: VisualDensity.compact,
            contentPadding: AppStyle.edgeInsetsH12,
            trailing: IconButton(
              visualDensity: VisualDensity.compact,
              onPressed: () {
                SyncService.instance.refreshClients();
              },
              icon: const Icon(Icons.refresh),
            ),
          ),
          SettingsCard(
            child: Obx(
              () => ListView.separated(
                shrinkWrap: true,
                padding: EdgeInsets.zero,
                physics: const NeverScrollableScrollPhysics(),
                separatorBuilder: (BuildContext context, int index) =>
                    AppStyle.divider,
                itemCount: SyncService.instance.scanClients.length,
                itemBuilder: (BuildContext context, int index) {
                  var client = SyncService.instance.scanClients[index];
                  return ListTile(
                    title: Text(client.name),
                    subtitle: Text(client.address),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () {
                      controller.connectClient(client);
                    },
                  );
                },
              ),
            ),
          ),
          AppStyle.vGap12,
          const Text(
            "未发现设备时，可扫描本机二维码或手动输入地址。\n请允许 Simple Live 通过防火墙访问局域网。",
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.grey,
              fontSize: 14,
            ),
          ),
        ],
      ),
    );
  }
}
