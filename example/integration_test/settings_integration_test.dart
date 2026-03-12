import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mixpanel_flutter_session_replay/mixpanel_flutter_session_replay.dart';

import 'integration_test_helpers.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'recording blocked when remote settings returns is_enabled false',
    (tester) async {
      final (:client, :uploadRequests) = createTestHttpClient(
        settingsEnabled: false,
      );

      final initResult = await MixpanelSessionReplay.initializeWithDependencies(
        token: 'test-token-disabled',
        distinctId: 'user-disabled',
        options: SessionReplayOptions(
          logLevel: testLogLevel,
          autoRecordSessionsPercent: 100.0,
          flushInterval: Duration.zero,
          autoMaskedViews: {},
          platformOptions: const PlatformOptions(
            mobile: MobileOptions(wifiOnly: false),
          ),
        ),
        httpClient: client,
      );

      expect(initResult.success, isTrue);
      final sdk = initResult.instance!;

      await tester.pumpWidget(
        MixpanelSessionReplayWidget(
          instance: sdk,
          child: const MaterialApp(home: SizedBox()),
        ),
      );
      await tester.pumpAndSettle();

      // Simulate foregrounding - triggers settings check + auto-start at 100%
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.runAsync(() => Future.delayed(Duration(milliseconds: 500)));
      await tester.pump();

      // After settings resolve as disabled, recording should be stopped
      expect(sdk.recordingState, RecordingState.notRecording);

      // Flush should produce no upload requests
      await tester.runAsync(() => sdk.flush());
      expect(
        uploadRequests,
        isEmpty,
        reason: 'No events should be uploaded when settings disabled',
      );
    },
  );

  testWidgets('recording blocked when settings check fails', (tester) async {
    final (:client, :uploadRequests) = createTestHttpClient(
      settingsStatusCode: 500,
    );

    final initResult = await MixpanelSessionReplay.initializeWithDependencies(
      token: 'test-token-fail',
      distinctId: 'user-fail',
      options: SessionReplayOptions(
        logLevel: testLogLevel,
        autoRecordSessionsPercent: 100.0,
        flushInterval: Duration.zero,
        autoMaskedViews: {},
        platformOptions: const PlatformOptions(
          mobile: MobileOptions(wifiOnly: false),
        ),
      ),
      httpClient: client,
    );

    expect(initResult.success, isTrue);
    final sdk = initResult.instance!;

    await tester.pumpWidget(
      MixpanelSessionReplayWidget(
        instance: sdk,
        child: const MaterialApp(home: SizedBox()),
      ),
    );
    await tester.pumpAndSettle();

    // Simulate foregrounding - triggers settings check (returns 500) + auto-start at 100%
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.runAsync(() => Future.delayed(Duration(milliseconds: 500)));
    await tester.pump();

    // After settings check fails, SDK defaults to disabled (fail closed)
    expect(sdk.recordingState, RecordingState.notRecording);

    // Flush should produce no upload requests
    await tester.runAsync(() => sdk.flush());
    expect(
      uploadRequests,
      isEmpty,
      reason: 'No events should be uploaded when settings check fails',
    );
  });
}
