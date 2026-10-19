import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:simple_live_account/simple_live_account.dart';
import 'package:simple_live_app/modules/sync/remote_sync/webdav/settings_backup_archive.dart';

void main() {
  test('public backup excludes stale account files and nested exports',
      () async {
    final directory =
        await Directory.systemTemp.createTemp('synthetic-backup-test-');
    addTearDown(() => directory.delete(recursive: true));
    for (final name in SettingsBackupArchive.fileNames) {
      await File(path.join(directory.path, name)).writeAsString('{"data":[]}');
    }
    await File(path.join(directory.path, 'SimpleLive_Settings.json'))
        .writeAsString(jsonEncode({
      'data': SettingsBackupPolicy.publicSettings({
        'volume': 50,
        'BilibiliCookie': 'synthetic-secret-cookie',
        'DouyinCookie': 'synthetic-secret-session',
        'WebDAVPassword': 'synthetic-secret-password',
      }),
    }));
    await File(path.join(directory.path, 'SimpleLive_bilibili_account.json'))
        .writeAsString('{"data":{"cookie":"synthetic-secret-cookie"}}');
    final nested =
        await Directory(path.join(directory.path, 'old-export')).create();
    await File(path.join(nested.path, 'SimpleLive_Settings.json'))
        .writeAsString('{"data":{"BilibiliCookie":"synthetic-secret-nested"}}');

    final zip = await SettingsBackupArchive.encode(directory);
    final archive = ZipDecoder().decodeBytes(zip);
    expect(archive.files.map((file) => file.name).toSet(), {
      'SimpleLive_follows.json',
      'SimpleLive_histories.json',
      'SimpleLive_blocked_word.json',
      'SimpleLive_Settings.json',
      'SimpleLive_Tags.json',
    });
    final payloads =
        archive.files.map((file) => utf8.decode(file.content)).join();
    expect(payloads, contains('"volume":50'));
    expect(payloads, isNot(contains('synthetic-secret')));
    expect(archive.files.any((file) => file.name.contains('/')), isFalse);
  });

  test('symlink cannot substitute an allowed backup file with account material',
      () async {
    if (Platform.isWindows) {
      return; // Windows test hosts may prohibit symlink creation.
    }
    final directory =
        await Directory.systemTemp.createTemp('synthetic-backup-link-');
    addTearDown(() => directory.delete(recursive: true));
    for (final name in SettingsBackupArchive.fileNames) {
      await File(path.join(directory.path, name)).writeAsString('{"data":[]}');
    }
    final accountFile = File(path.join(directory.path, 'old-account.json'));
    await accountFile.writeAsString('{"cookie":"synthetic-secret-cookie"}');
    final settingsPath = path.join(directory.path, 'SimpleLive_Settings.json');
    await File(settingsPath).delete();
    await Link(settingsPath).create(accountFile.path);
    await expectLater(SettingsBackupArchive.encode(directory),
        throwsA(isA<FileSystemException>()));
  });
}
