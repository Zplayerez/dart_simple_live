/// Account material never belongs in ordinary settings exports. Local logout
/// markers must survive restoring preferences from another device as well.
class SettingsBackupPolicy {
  static bool isPrivateKey(Object? key) {
    final name = key.toString().toLowerCase();
    return name.startsWith('platformaccountrestoreblocked.') ||
        RegExp(r'cookie|password|secret|credential|token').hasMatch(name);
  }

  static Map<String, dynamic> publicSettings(Map<dynamic, dynamic> settings) => {
    for (final entry in settings.entries)
      if (!isPrivateKey(entry.key)) entry.key.toString(): entry.value,
  };
}
