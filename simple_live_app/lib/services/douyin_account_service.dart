import 'package:get/get.dart';
import 'package:simple_live_account/simple_live_account.dart';

/// Compatibility facade; a configured ttwid is not a verified account.
class DouyinAccountService extends GetxService {
  static DouyinAccountService get instance => Get.find();

  final hasCookie = false.obs;
  Worker? _worker;
  PlatformAccountManager get _manager => PlatformAccountManager.instance;
  String get cookie => _manager.credentialFor('douyin');

  @override
  void onInit() {
    super.onInit();
    _refresh();
    _worker = ever(_manager.accounts, (_) => _refresh());
  }

  void _refresh() {
    hasCookie.value = _manager.account('douyin').hasCredential;
  }

  Future<PlatformAccountState> setCookie(String cookie) =>
      _manager.importCookie('douyin', cookie);

  Future<PlatformAccountState> clearCookie() => _manager.logout('douyin');

  @override
  void onClose() {
    _worker?.dispose();
    super.onClose();
  }
}
