import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:simple_live_account/simple_live_account.dart';
import 'package:simple_live_account/widgets/account_labels.dart';
import 'package:simple_live_app/app/controller/base_controller.dart';
import 'package:simple_live_app/routes/route_path.dart';
import 'package:simple_live_app/modules/mine/account/platform_web_cookie_cleanup.dart';
import 'package:simple_live_app/modules/mine/account/platform_web_login_policy.dart';

class BiliBiliWebLoginController extends BaseController {
  InAppWebViewController? webViewController;
  final CookieManager cookieManager = CookieManager.instance();
  bool _importing = false;
  final currentHost = 'passport.bilibili.com'.obs;
  final blockedNavigation = false.obs;
  Uri? _currentUri;
  bool _closed = false;
  bool _autoAttempted = false;

  @override
  void onInit() {
    PlatformInAppWebViewController.debugLoggingSettings.enabled = false;
    super.onInit();
  }

  void onWebViewCreated(InAppWebViewController controller) {
    webViewController = controller;
    controller.loadUrl(
      urlRequest: URLRequest(
        url: WebUri('https://passport.bilibili.com/login'),
      ),
    );
  }

  Future<void> toQRLogin() async {
    await Get.toNamed(RoutePath.kBiliBiliQRLogin);
    if (!_closed &&
        PlatformAccountManager.instance.account('bilibili').status ==
            LiveAccountStatus.verified) {
      Get.back();
    }
  }

  Future<void> onLocationChanged(
      InAppWebViewController controller, Uri? uri) async {
    if (_closed) return;
    _currentUri = uri;
    currentHost.value = uri?.host ?? '';
    blockedNavigation.value =
        uri != null && !isOfficialAccountPage('bilibili', uri);
    recordPlatformWebCookieScope('bilibili', uri);
    if (blockedNavigation.value) await controller.stopLoading();
  }

  void onLoadStop(InAppWebViewController controller, Uri? uri) {
    onLocationChanged(controller, uri);
    if (isOfficialAccountPage('bilibili', uri) && uri?.host == 'm.bilibili.com') {
      logined();
    }
  }

  Future<bool> logined({bool manual = false}) async {
    if (_closed ||
        _importing ||
        (!manual && _autoAttempted) ||
        !isOfficialAccountPage('bilibili', _currentUri)) {
      return false;
    }
    _importing = true;
    try {
      final cookies = await cookieManager.getCookies(
        url: WebUri('https://www.bilibili.com'),
      );
      if (_closed) return false;
      // Anonymous site cookies alone must not replace the current account.
      if (!cookies.any(
        (cookie) => cookie.name == 'SESSDATA' && cookie.value.isNotEmpty,
      )) {
        if (manual) SmartDialog.showToast('尚未获取到登录凭据，请先完成官方网页登录');
        return false;
      }
      _autoAttempted = true;
      final state = await PlatformAccountManager.instance.importCookie(
        'bilibili',
        cookies.map((cookie) => '${cookie.name}=${cookie.value}').join(';'),
      );
      if (_closed) return false;
      SmartDialog.showToast(accountResultMessage(state));
      if (state.status == LiveAccountStatus.verified) {
        Get.back();
        return true;
      }
      return false;
    } catch (_) {
      if (!_closed) SmartDialog.showToast('暂时无法完成账号验证，请稍后重试');
      return false;
    } finally {
      _importing = false;
    }
  }

  @override
  void onClose() {
    _closed = true;
    webViewController = null;
    super.onClose();
  }
}
