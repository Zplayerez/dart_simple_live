import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:simple_live_account/widgets/account_labels.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/modules/mine/account/account_controller.dart';

class AccountPage extends GetView<AccountController> {
  const AccountPage({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('账号管理')),
      body: ListView(
        children: [
          const Padding(
            padding: AppStyle.edgeInsetsA12,
            child: Text(
              '各平台账号独立管理。导入凭据后会尝试验证，未登录也可按平台游客权限观看。',
              textAlign: TextAlign.center,
            ),
          ),
          for (final siteId in accountPlatformIds)
            Obx(() {
              final state = controller.accounts.account(siteId);
              return ListTile(
                leading: Image.asset(
                  'assets/images/${siteId == 'bilibili' ? 'bilibili_2' : siteId}.png',
                  width: 36,
                  height: 36,
                ),
                title: Text(accountPlatformName(siteId)),
                subtitle: Text(accountSummary(state)),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => controller.openPlatform(siteId),
              );
            }),
        ],
      ),
    );
  }
}
