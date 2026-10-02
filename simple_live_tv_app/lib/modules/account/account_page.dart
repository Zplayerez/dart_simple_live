import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:simple_live_account/simple_live_account.dart';
import 'package:simple_live_account/widgets/account_labels.dart';
import 'package:simple_live_account/widgets/account_pairing_page.dart';
import 'package:simple_live_tv_app/app/app_focus_node.dart';
import 'package:simple_live_tv_app/app/app_style.dart';
import 'package:simple_live_tv_app/app/utils.dart';
import 'package:simple_live_tv_app/modules/account/cookie_import_dialog.dart';
import 'package:simple_live_tv_app/routes/app_navigation.dart';
import 'package:simple_live_tv_app/services/sync_service.dart';
import 'package:simple_live_tv_app/widgets/app_scaffold.dart';
import 'package:simple_live_tv_app/widgets/button/highlight_button.dart';
import 'package:simple_live_tv_app/widgets/button/highlight_list_tile.dart';

class AccountPage extends StatefulWidget {
  final String siteId;

  const AccountPage({required this.siteId, super.key});

  @override
  State<AccountPage> createState() => _AccountPageState();
}

class _AccountPageState extends State<AccountPage> {
  final _backFocus = AppFocusNode();
  final _qrFocus = AppFocusNode();
  final _importFocus = AppFocusNode();
  final _receiveFocus = AppFocusNode();
  final _verifyFocus = AppFocusNode();
  final _logoutFocus = AppFocusNode();
  bool _working = false;

  PlatformAccountManager get _accounts => PlatformAccountManager.instance;

  @override
  void dispose() {
    for (final node in [
      _backFocus,
      _qrFocus,
      _importFocus,
      _receiveFocus,
      _verifyFocus,
      _logoutFocus,
    ]) {
      node.dispose();
    }
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_working) return;
    setState(() => _working = true);
    try {
      await action();
    } on FormatException {
      SmartDialog.showToast('Cookie 格式无效，请输入完整的名称=值形式');
    } catch (_) {
      SmartDialog.showToast('账号操作未完成，请稍后重试');
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _receive() async {
    await Get.to(() => AccountReceivePage(
          siteId: widget.siteId,
          onStart: (confirm, onStatus) => SyncService.instance
              .startAccountPairing(widget.siteId, confirm, onStatus),
          onCancel: () => SyncService.instance.cancelAccountPairing(),
        ));
    if (mounted) _receiveFocus.requestFocus();
  }

  Future<void> _import() async {
    final cookie = await Get.dialog<String>(
      CookieImportDialog(siteId: widget.siteId),
    );
    if (cookie == null || cookie.trim().isEmpty || !mounted) return;
    await _run(() async {
      final state = await _accounts.importCookie(widget.siteId, cookie);
      SmartDialog.showToast(accountResultMessage(state));
    });
    if (mounted) _importFocus.requestFocus();
  }

  Future<void> _verify() => _run(() async {
        final state = await _accounts.verify(widget.siteId);
        SmartDialog.showToast(accountResultMessage(state));
      });

  Future<void> _logout() async {
    final confirmed = await Utils.showAlertDialog(
      '确定要退出${accountPlatformName(widget.siteId)}并清除本机凭据吗？',
      title: '退出账号',
    );
    if (!confirmed || !mounted) return;
    await _run(() async {
      final state = await _accounts.logout(widget.siteId);
      SmartDialog.showToast(state.storageMessage ??
          '已清除${accountPlatformName(widget.siteId)}账号凭据');
    });
    if (mounted) _importFocus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      child: FocusTraversalGroup(
        child: Column(
          children: [
            AppStyle.vGap32,
            Row(
              children: [
                AppStyle.hGap48,
                HighlightButton(
                  focusNode: _backFocus,
                  iconData: Icons.arrow_back,
                  text: '返回',
                  onTap: () => Get.back(),
                ),
                AppStyle.hGap32,
                Text(
                  '${accountPlatformName(widget.siteId)}账号',
                  style: AppStyle.titleStyleWhite,
                ),
              ],
            ),
            Expanded(
              child: Center(
                child: SizedBox(
                  width: 960.w,
                  child: Obx(() {
                    final state = _accounts.account(widget.siteId);
                    final busy =
                        _working || state.status == LiveAccountStatus.verifying;
                    return ListView(
                      padding: AppStyle.edgeInsetsA48,
                      children: [
                        Row(
                          children: [
                            if (state.status == LiveAccountStatus.verified &&
                                (state.avatarUrl?.isNotEmpty ?? false)) ...[
                              CircleAvatar(
                                radius: 32.w,
                                foregroundImage: NetworkImage(state.avatarUrl!),
                                onForegroundImageError: (_, __) {},
                                child: const Icon(Icons.person_outline),
                              ),
                              AppStyle.hGap24,
                            ],
                            Expanded(
                                child: Text(
                              accountSummary(state),
                              style: AppStyle.titleStyleWhite,
                            )),
                          ],
                        ),
                        AppStyle.vGap24,
                        Text(
                          accountDetails(state),
                          style: AppStyle.textStyleWhite,
                        ),
                        AppStyle.vGap24,
                        if (busy) const LinearProgressIndicator(),
                        if (widget.siteId == 'bilibili') ...[
                          HighlightListTile(
                            focusNode: _qrFocus,
                            autofocus: true,
                            title: '扫码登录',
                            subtitle: '使用哔哩哔哩 App 扫描二维码',
                            leading: const Icon(Icons.qr_code),
                            onTap: busy
                                ? null
                                : () {
                                    AppNavigator.toBiliBiliLogin();
                                  },
                          ),
                          AppStyle.vGap24,
                        ],
                        HighlightListTile(
                          focusNode: _receiveFocus,
                          autofocus: widget.siteId != 'bilibili',
                          title: '从其他设备接收账号',
                          subtitle: '手机或电脑配对，确认后加密传入',
                          leading: const Icon(Icons.devices),
                          onTap: busy
                              ? null
                              : () {
                                  _receive();
                                },
                        ),
                        AppStyle.vGap24,
                        HighlightListTile(
                          focusNode: _importFocus,
                          title:
                              state.hasCredential ? '更新 Cookie' : '导入 Cookie',
                          subtitle: '完整 Cookie；可使用遥控器和屏幕键盘输入',
                          leading: const Icon(Icons.edit_outlined),
                          onTap: busy
                              ? null
                              : () {
                                  _import();
                                },
                        ),
                        if (state.hasCredential) ...[
                          AppStyle.vGap24,
                          HighlightListTile(
                            focusNode: _verifyFocus,
                            title: '重新验证',
                            leading: const Icon(Icons.refresh),
                            onTap: busy
                                ? null
                                : () {
                                    _verify();
                                  },
                          ),
                        ],
                        if (state.hasCredential ||
                            state.storageMessage != null) ...[
                          AppStyle.vGap24,
                          HighlightListTile(
                            focusNode: _logoutFocus,
                            title: state.hasCredential ? '退出并清除凭据' : '重试清除本机凭据',
                            leading: const Icon(Icons.logout),
                            onTap: busy
                                ? null
                                : () {
                                    _logout();
                                  },
                          ),
                        ],
                        AppStyle.vGap24,
                        Text(
                          '各平台账号独立管理。保存凭据不代表已登录，未登录也可按平台游客权限观看。',
                          style: AppStyle.textStyleWhite,
                        ),
                      ],
                    );
                  }),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
