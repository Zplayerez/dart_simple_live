import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Injectable boundary: implementations must never fall back to plaintext.
abstract class CredentialStore {
  Future<String?> read(String siteId);
  Future<void> write(String siteId, String cookie);
  Future<void> delete(String siteId);
}

class SystemCredentialStore implements CredentialStore {
  SystemCredentialStore({FlutterSecureStorage? storage})
    : _storage =
          storage ??
          const FlutterSecureStorage(
            aOptions: AndroidOptions(encryptedSharedPreferences: true),
            iOptions: IOSOptions(
              accessibility: KeychainAccessibility.first_unlock_this_device,
            ),
            mOptions: MacOsOptions(
              accessibility: KeychainAccessibility.first_unlock_this_device,
            ),
          );

  final FlutterSecureStorage _storage;
  static const _prefix = 'simple_live.platform_account.v1.';

  @override
  Future<String?> read(String siteId) => _storage.read(key: '$_prefix$siteId');

  @override
  Future<void> write(String siteId, String cookie) =>
      _storage.write(key: '$_prefix$siteId', value: cookie);

  @override
  Future<void> delete(String siteId) => _storage.delete(key: '$_prefix$siteId');
}
