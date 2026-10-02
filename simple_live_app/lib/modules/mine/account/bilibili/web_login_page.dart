import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/modules/mine/account/bilibili/web_login_controller.dart';
import 'package:simple_live_app/modules/mine/account/platform_web_login_policy.dart';

class BiliBiliWebLoginPage extends GetView<BiliBiliWebLoginController> {
  const BiliBiliWebLoginPage({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("哔哩哔哩账号登录"),
        actions: [
          TextButton(
            onPressed: () => controller.logined(manual: true),
            child: const Text('完成登录'),
          ),
          TextButton.icon(
            onPressed: controller.toQRLogin,
            icon: const Icon(Icons.qr_code),
            label: const Text("二维码登录"),
          ),
        ],
      ),
      body: Column(children: [
        Padding(
            padding: const EdgeInsets.all(8),
            child: Obx(() => Text('当前网站：${controller.currentHost.value}'))),
        Expanded(
            child: Stack(children: [
          InAppWebView(
            onLoadStart: controller.onLocationChanged,
            onUpdateVisitedHistory: (webController, uri, _) =>
                controller.onLocationChanged(webController, uri),
            onWebViewCreated: controller.onWebViewCreated,
            onLoadStop: controller.onLoadStop,
            initialSettings: InAppWebViewSettings(
              userAgent:
                  "Mozilla/5.0 (iPhone; CPU iPhone OS 13_2_3 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/13.0.3 Mobile/15E148 Safari/604.1 Edg/118.0.0.0",
              useShouldOverrideUrlLoading: true,
            ),
            shouldOverrideUrlLoading: (webController, navigationAction) async {
              var uri = navigationAction.request.url;
              if (!isAllowedAccountNavigation('bilibili', uri,
                  isMainFrame: navigationAction.isForMainFrame)) {
                return NavigationActionPolicy.CANCEL;
              }
              if (navigationAction.isForMainFrame &&
                  (uri?.host == "m.bilibili.com" ||
                      uri?.host == "www.bilibili.com")) {
                if (await controller.logined()) {
                  return NavigationActionPolicy.CANCEL;
                }
              }
              return NavigationActionPolicy.ALLOW;
            },
          ),
          Obx(() => controller.blockedNavigation.value
              ? Positioned.fill(
                  child: ColoredBox(
                      color: Theme.of(context).scaffoldBackgroundColor,
                      child: const Center(child: Text('已阻止显示非官方网站'))))
              : const SizedBox.shrink()),
        ])),
      ]),
    );
  }
}
