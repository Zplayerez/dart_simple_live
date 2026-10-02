import 'package:get/get.dart';
import 'package:simple_live_account/simple_live_account.dart';

/// Compatibility facade for existing Bilibili QR and navigation consumers.
/// The shared manager owns all credentials, persistence and validation.
class BiliBiliAccountService extends GetxService {
  static BiliBiliAccountService get instance => Get.find();

  final logined = false.obs;
  final name = '未登录'.obs;
  Worker? _worker;
  Future<PlatformAccountState>? _pendingImport;

  PlatformAccountManager get _manager => PlatformAccountManager.instance;
  String get cookie => _manager.credentialFor('bilibili');
  int get uid => int.tryParse(_manager.account('bilibili').userId ?? '') ?? 0;

  @override
  void onInit() {
    super.onInit();
    _refresh();
    _worker = ever(_manager.accounts, (_) => _refresh());
  }

  void _refresh() {
    final state = _manager.account('bilibili');
    // A transient verification outage does not sign a previously verified user out.
    logined.value =
        state.hasCredential &&
        state.userId != null &&
        state.status != LiveAccountStatus.expired;
    name.value = state.displayName ?? state.message;
  }

  Future<PlatformAccountState> setCookie(String cookie) {
    final operation = _manager.importCookie('bilibili', cookie, verify: false);
    _pendingImport = operation;
    return operation;
  }

  Future<PlatformAccountState> loadUserInfo() async {
    await _pendingImport;
    return _manager.verify('bilibili');
  }

  Future<PlatformAccountState> logout() => _manager.logout('bilibili');

  @override
  void onClose() {
    _worker?.dispose();
    super.onClose();
  }
}
