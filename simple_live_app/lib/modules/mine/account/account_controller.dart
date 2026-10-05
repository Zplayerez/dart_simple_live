import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:simple_live_account/simple_live_account.dart';
import 'package:simple_live_account/widgets/account_labels.dart';
import 'package:simple_live_account/widgets/account_pairing_page.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_app/modules/mine/account/cookie_import_dialog.dart';
import 'package:simple_live_app/routes/route_path.dart';
import 'package:simple_live_app/services/sync_service.dart';
import 'package:simple_live_app/modules/mine/account/platform_web_login_page.dart';
import 'package:simple_live_app/modules/mine/account/platform_web_login_policy.dart';

class AccountController extends GetxController {
  PlatformAccountManager get accounts => PlatformAccountManager.instance;

  void openPlatform(String siteId) {
    Utils.showBottomSheet(
      title: '${accountPlatformName(siteId)}账号',
      child: Obx(() {
        final state = accounts.account(siteId);
        final busy = accounts.isBusy(siteId);
        return ListView(
          children: [
            ListTile(
              leading: state.status == LiveAccountStatus.verified &&
                      (state.avatarUrl?.isNotEmpty ?? false)
                  ? CircleAvatar(
                      foregroundImage: NetworkImage(state.avatarUrl!),
                      onForegroundImageError: (_, __) {},
                      child: const Icon(Icons.person_outline),
                    )
                  : const Icon(Icons.account_circle_outlined),
              title: Text(accountSummary(state)),
              subtitle: Text(accountDetails(state)),
            ),
            if (busy) const LinearProgressIndicator(),
            ListTile(
              dense: true,
              title: Text(accounts.cleaningAccounts.contains(siteId)
                  ? '正在清理登录信息，请稍候…'
                  : accountNextStep(state)),
            ),
            if (platformWebLoginSupported)
              ListTile(
                leading: const Icon(Icons.account_circle_outlined),
                title: Text(state.status == LiveAccountStatus.expired
                    ? '重新登录'
                    : '网页登录'),
                subtitle: const Text('在平台官方页面完成登录'),
                trailing: const Icon(Icons.chevron_right),
                enabled: !busy,
                onTap: () {
                  Get.back();
                  Get.to(() => PlatformWebLoginPage(siteId: siteId));
                },
              ),
            if (siteId == 'bilibili') ...[
              ListTile(
                leading: const Icon(Icons.qr_code),
                title: const Text('扫码登录'),
                subtitle: const Text('使用哔哩哔哩 App 扫描二维码'),
                trailing: const Icon(Icons.chevron_right),
                enabled: !busy,
                onTap: () {
                  Get.back();
                  Get.toNamed(RoutePath.kBiliBiliQRLogin);
                },
              ),
            ],
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: Text(state.hasCredential ? '更新 Cookie' : '导入 Cookie'),
              subtitle: const Text('导入完整 Cookie，保存后尝试验证账号状态'),
              trailing: const Icon(Icons.chevron_right),
              enabled: !busy,
              onTap: () => importCookie(siteId),
            ),
            if (state.hasCredential) ...[
              ListTile(
                leading: const Icon(Icons.refresh),
                title: const Text('重新验证'),
                enabled: !busy,
                onTap: () => verify(siteId),
              ),
            ],
            if (state.hasCredential || state.storageMessage != null)
              ListTile(
                leading: const Icon(Icons.logout),
                title: Text(state.hasCredential ? '退出并清除凭据' : '重试清除本机凭据'),
                enabled: !busy,
                onTap: () => logout(siteId),
              ),
            ListTile(
              leading: const Icon(Icons.devices),
              title: const Text('从其他设备接收账号'),
              subtitle: const Text('同一局域网内配对，确认后加密传入'),
              enabled: !busy,
              onTap: () => receiveAccount(siteId),
            ),
            if (state.hasCredential)
              ListTile(
                leading: const Icon(Icons.send_outlined),
                title: const Text('发送到另一台设备'),
                subtitle: const Text('扫描或粘贴接收设备的配对信息'),
                enabled: !busy,
                onTap: () => sendAccount(siteId),
              ),
          ],
        );
      }),
    );
  }

  void receiveAccount(String siteId) {
    Get.back();
    Get.to(() => AccountReceivePage(
          siteId: siteId,
          onStart: (confirm, onStatus) => SyncService.instance
              .startAccountPairing(siteId, confirm, onStatus),
          onCancel: () => SyncService.instance.cancelAccountPairing(),
        ));
  }

  void sendAccount(String siteId) {
    Get.back();
    Get.to(() => AccountSendPage(
          siteId: siteId,
          scan: Platform.isAndroid || Platform.isIOS
              ? () async => await Get.toNamed<String>(RoutePath.kSyncScan)
              : null,
        ));
  }

  Future<void> importCookie(String siteId) async {
    final cookie = await Get.dialog<String>(CookieImportDialog(siteId: siteId));
    if (cookie == null || cookie.trim().isEmpty) return;
    try {
      final state = await accounts.importCookie(siteId, cookie);
      SmartDialog.showToast(accountResultMessage(state));
    } on FormatException {
      SmartDialog.showToast('Cookie 格式无效，请输入完整的名称=值形式');
    } catch (_) {
      SmartDialog.showToast('未能导入 Cookie，请重试');
    }
  }

  Future<void> verify(String siteId) async {
    try {
      final state = await accounts.verify(siteId);
      SmartDialog.showToast(accountResultMessage(state));
    } catch (_) {
      SmartDialog.showToast('暂时无法验证，请稍后重试');
    }
  }

  Future<void> logout(String siteId) async {
    final confirmed = await Utils.showAlertDialog(
      '确定要退出${accountPlatformName(siteId)}并清除本机凭据吗？',
      title: '退出账号',
    );
    if (!confirmed) return;
    try {
      final state = await accounts.logout(siteId);
      SmartDialog.showToast(
          state.storageMessage ?? '已清除${accountPlatformName(siteId)}账号凭据');
    } catch (_) {
      SmartDialog.showToast('清除凭据未完成，请重试');
    }
  }
}
