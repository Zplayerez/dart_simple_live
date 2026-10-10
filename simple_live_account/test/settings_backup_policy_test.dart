import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_account/src/settings_backup_policy.dart';

void main() {
  test('ordinary backup excludes old credentials and device logout markers', () {
    final settings = {
      'BilibiliCookie': 'private-cookie', 'DouyinCookie': 'another-cookie',
      'WebDAVPassword': 'private-password',
      'PlatformAccountRestoreBlocked.douyu': true,
      'themeMode': 2, 'playerVolume': 80,
    };
    expect(SettingsBackupPolicy.publicSettings(settings),
      {'themeMode': 2, 'playerVolume': 80});
  });
  test('legacy restore cannot overwrite credentials or local logout state', () {
    final current = <String, dynamic>{'BilibiliCookie': 'local',
      'PlatformAccountRestoreBlocked.douyu': true, 'themeMode': 1};
    final incoming = {'BilibiliCookie': 'remote',
      'PlatformAccountRestoreBlocked.douyu': false, 'themeMode': 2};
    current.removeWhere((key, value) => !SettingsBackupPolicy.isPrivateKey(key));
    current.addAll(SettingsBackupPolicy.publicSettings(incoming));
    expect(current, {'BilibiliCookie': 'local',
      'PlatformAccountRestoreBlocked.douyu': true, 'themeMode': 2});
  });
}
