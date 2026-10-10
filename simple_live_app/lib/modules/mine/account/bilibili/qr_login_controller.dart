import 'dart:async';

import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:simple_live_account/simple_live_account.dart';
import 'package:simple_live_account/widgets/account_labels.dart';
import 'package:simple_live_app/requests/http_client.dart';

enum QRStatus { loading, unscanned, scanned, expired, failed }

class BiliBiliQRLoginController extends GetxController {
  @override
  void onInit() {
    loadQRCode();
    super.onInit();
  }

  Timer? timer;
  var qrcodeUrl = ''.obs;
  var qrcodeKey = '';
  Rx<QRStatus> qrStatus = QRStatus.loading.obs;
  int _generation = 0;
  bool _polling = false;
  bool _closed = false;

  Future<void> loadQRCode() async {
    final generation = ++_generation;
    timer?.cancel();
    qrcodeKey = '';
    qrcodeUrl.value = '';
    qrStatus.value = QRStatus.loading;
    try {
      final result = await HttpClient.instance.getJson(
        'https://passport.bilibili.com/x/passport-login/web/qrcode/generate',
      );
      if (_closed || generation != _generation) return;
      if (result['code'] != 0) {
        throw const FormatException('QR generation failed');
      }
      qrcodeKey = result['data']['qrcode_key'];
      qrcodeUrl.value = result['data']['url'];
      qrStatus.value = QRStatus.unscanned;
      timer = Timer.periodic(const Duration(seconds: 3), (_) => pollQRStatus());
    } catch (_) {
      if (_closed || generation != _generation) return;
      SmartDialog.showToast('无法获取登录二维码，请重试');
      qrStatus.value = QRStatus.failed;
    }
  }

  Future<void> pollQRStatus() async {
    if (_polling || _closed || qrcodeKey.isEmpty) return;
    _polling = true;
    final generation = _generation;
    try {
      final response = await HttpClient.instance.get(
        'https://passport.bilibili.com/x/passport-login/web/qrcode/poll',
        queryParameters: {'qrcode_key': qrcodeKey},
      );
      if (_closed || generation != _generation) return;
      if (response.data['code'] != 0) {
        throw const FormatException('QR polling failed');
      }
      final code = response.data['data']['code'];
      if (code == 0) {
        timer?.cancel();
        qrcodeKey = '';
        final cookies = response.headers['set-cookie']
                ?.map((value) => value.split(';').first)
                .toList() ??
            <String>[];
        if (cookies.isEmpty) {
          qrStatus.value = QRStatus.failed;
          SmartDialog.showToast('未收到账号凭据，请重新扫码');
          return;
        }
        final state = await PlatformAccountManager.instance.importCookie(
          'bilibili',
          cookies.join(';'),
        );
        if (_closed || generation != _generation) return;
        SmartDialog.showToast(accountResultMessage(state));
        Get.back();
      } else if (code == 86038) {
        qrStatus.value = QRStatus.expired;
        qrcodeKey = '';
        timer?.cancel();
      } else if (code == 86090) {
        qrStatus.value = QRStatus.scanned;
      }
    } catch (_) {
      if (_closed || generation != _generation) return;
      if (qrcodeKey.isEmpty) qrStatus.value = QRStatus.failed;
      SmartDialog.showToast('暂时无法完成扫码验证，请稍后重试');
    } finally {
      _polling = false;
    }
  }

  @override
  void onClose() {
    _closed = true;
    _generation++;
    qrcodeKey = '';
    qrcodeUrl.value = '';
    timer?.cancel();
    super.onClose();
  }
}
