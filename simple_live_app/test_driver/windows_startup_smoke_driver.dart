import 'package:integration_test/integration_test_driver.dart';

Future<void> main() => integrationDriver(
      timeout: const Duration(minutes: 4),
      writeResponseOnFailure: true,
      responseDataCallback: (data) => writeResponseData(
        data ?? {},
        testOutputFilename: 'report',
        destinationDirectory: 'build/windows-startup-smoke',
      ),
    );
