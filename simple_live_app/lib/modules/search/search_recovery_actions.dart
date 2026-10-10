import 'package:flutter/material.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:simple_live_app/modules/mine/account/account_controller.dart';
import 'package:url_launcher/url_launcher.dart';

class SearchRecoveryActions extends StatelessWidget {
  final String keyword;
  final bool anchors;
  const SearchRecoveryActions(
      {required this.keyword, required this.anchors, super.key});

  @override
  Widget build(BuildContext context) => Wrap(spacing: 8, children: [
        TextButton.icon(
            onPressed: () => AccountController().openPlatform('douyin'),
            icon: const Icon(Icons.account_circle_outlined),
            label: const Text('抖音登录')),
        TextButton.icon(
            onPressed: () async {
              try {
                final opened = await launchUrl(
                    Uri.https('www.douyin.com', '/root/search/$keyword',
                        {'type': anchors ? 'user' : 'live'}),
                    mode: LaunchMode.externalApplication);
                if (!opened) SmartDialog.showToast('无法打开浏览器，请稍后重试');
              } catch (_) {
                SmartDialog.showToast('无法打开浏览器，请稍后重试');
              }
            },
            icon: const Icon(Icons.open_in_new),
            label: const Text('官网搜索')),
      ]);
}
