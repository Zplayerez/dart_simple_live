import 'dart:convert';
import 'dart:io';

import 'package:integration_test/integration_test_driver.dart';

Future<void> main() => integrationDriver(
      timeout: const Duration(minutes: 4),
      writeResponseOnFailure: true,
      responseDataCallback: (data) async {
        final output = Directory('build/windows-webview-smoke');
        await output.create(recursive: true);
        final report = Map<String, dynamic>.from(data ?? {});
        final captures = report['captures'] as List<dynamic>? ?? [];
        for (final capture in captures) {
          final png = capture.remove('pngBase64') as String?;
          if (png == null) continue;
          final filename = '${capture['name']}.png';
          await File('${output.path}/$filename')
              .writeAsBytes(base64Decode(png));
          capture['screenshot'] = filename;
        }
        await writeResponseData(
          report,
          testOutputFilename: 'report',
          destinationDirectory: output.path,
        );
      },
    );
