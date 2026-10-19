import 'dart:io';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as path;

/// Explicit public export format. Never recurse into a shared staging folder.
class SettingsBackupArchive {
  static const fileNames = {
    'SimpleLive_follows.json',
    'SimpleLive_histories.json',
    'SimpleLive_blocked_word.json',
    'SimpleLive_Settings.json',
    'SimpleLive_Tags.json',
  };

  static Future<List<int>> encode(Directory directory) async {
    final archive = Archive();
    for (final name in fileNames) {
      final filePath = path.join(directory.path, name);
      // Export inputs are freshly written regular files, never symlinks to
      // another directory that might contain an older account backup.
      if (await FileSystemEntity.type(filePath, followLinks: false) !=
          FileSystemEntityType.file) {
        throw const FileSystemException('A public backup file is missing');
      }
      final bytes = await File(filePath).readAsBytes();
      archive.addFile(ArchiveFile(name, bytes.length, bytes));
    }
    return ZipEncoder().encode(archive);
  }
}
