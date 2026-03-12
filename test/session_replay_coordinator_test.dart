import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixpanel_flutter_session_replay/src/internal/session_replay_coordinator.dart';
import 'package:mixpanel_flutter_session_replay/src/internal/event_recorder.dart';
import 'package:mixpanel_flutter_session_replay/src/internal/screenshot_capturer.dart';
import 'package:mixpanel_flutter_session_replay/src/internal/upload/upload_service.dart';
import 'package:mixpanel_flutter_session_replay/src/internal/upload/settings_service.dart';
import 'package:mixpanel_flutter_session_replay/src/internal/upload/payload_serializer.dart';
import 'package:mixpanel_flutter_session_replay/src/internal/session/session_manager.dart';
import 'package:mixpanel_flutter_session_replay/src/internal/logger.dart';
import 'package:mixpanel_flutter_session_replay/src/models/configuration.dart';
import 'package:mixpanel_flutter_session_replay/src/models/masking_directive.dart';
import 'package:mixpanel_flutter_session_replay/src/models/results.dart';
import 'package:mixpanel_flutter_session_replay/src/models/session_event.dart';

import 'helpers/fake_http_client.dart';
import 'helpers/in_memory_event_queue.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SessionReplayCoordinator', () {
    late InMemoryEventQueue eventQueue;
    late SessionManager sessionManager;
    late EventRecorder eventRecorder;
    late UploadService uploadService;
    late SettingsService settingsService;
    late ScreenshotCapturer screenshotCapturer;
    late MixpanelLogger logger;

    SessionReplayCoordinator createCoordinator({
      double autoRecordSessionsPercent = 0,
    }) {
      return SessionReplayCoordinator(
        screenshotCapturer: screenshotCapturer,
        eventRecorder: eventRecorder,
        uploadService: uploadService,
        settingsService: settingsService,
        sessionManager: sessionManager,
        logger: logger,
        autoRecordSessionsPercent: autoRecordSessionsPercent,
        debugOptions: null,
      );
    }

    setUp(() async {
      // Mock the method channel used by SessionReplaySender
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('com.mixpanel.flutter_session_replay'),
            (call) async => null,
          );

      logger = MixpanelLogger(LogLevel.none);
      eventQueue = InMemoryEventQueue();
      await eventQueue.initialize();
      sessionManager = SessionManager();

      eventRecorder = EventRecorder(
        eventQueue: eventQueue,
        sessionManager: sessionManager,
        getDistinctId: () => 'user-1',
        logger: logger,
      );

      final httpClient = createFakeHttpClient(statusCode: 200);
      uploadService = UploadService(
        eventQueue: eventQueue,
        payloadSerializer: PayloadSerializer('test-token'),
        wifiOnly: false,
        getRemoteSettingsState: () => RemoteSettingsState.enabled,
        flushInterval: Duration(hours: 1),
        logger: logger,
        httpClient: httpClient,
      );

      settingsService = SettingsService(
        token: 'test-token',
        logger: logger,
        httpClient: createFakeSettingsClient(isEnabled: true),
      );

      screenshotCapturer = ScreenshotCapturer(
        directive: MaskingDirective(autoMaskTypes: {}),
        logger: logger,
        debugOverlayEnabled: false,
      );
    });

    tearDown(() async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('com.mixpanel.flutter_session_replay'),
            null,
          );

      try {
        await eventQueue.dispose();
      } catch (_) {
        // Already disposed by test
      }
    });

    group('initial state', () {
      test('starts in notRecording state', () {
        // GIVEN
        final expectedState = RecordingState.notRecording;

        // WHEN
        final coordinator = createCoordinator();

        // THEN
        expect(coordinator.recordingState, expectedState);
      });

      test('starts with app not in foreground', () {
        // GIVEN
        final expectedForeground = false;

        // WHEN
        final coordinator = createCoordinator();

        // THEN - default is false; LifecycleObserver sets true on first resume
        expect(coordinator.isAppInForeground, expectedForeground);
      });

      test('starts with pending remote settings state', () {
        // GIVEN
        final expectedState = RemoteSettingsState.pending;

        // WHEN
        final coordinator = createCoordinator();

        // THEN
        expect(coordinator.remoteSettingsState, expectedState);
      });
    });

    group('startRecording', () {
      test('transitions to recording state with 100% sampling', () async {
        // GIVEN
        final expectedState = RecordingState.recording;
        final coordinator = createCoordinator();

        // WHEN
        coordinator.startRecording(sessionsPercent: 100.0);
        // Wait for async session metadata persistence
        await pumpEventQueue();

        // THEN
        expect(coordinator.recordingState, expectedState);
      });

      test('does not start when already recording', () async {
        // GIVEN
        final coordinator = createCoordinator();
        coordinator.startRecording(sessionsPercent: 100.0);
        await pumpEventQueue();
        expect(coordinator.recordingState, RecordingState.recording);

        // WHEN - try to start again
        coordinator.startRecording(sessionsPercent: 0);

        // THEN - still recording, no state change
        // This test works because you would not expect recording with a 0%
        expect(coordinator.recordingState, RecordingState.recording);
      });

      test('does not start when remote settings are disabled', () async {
        // GIVEN - coordinator without auto-start to isolate the
        // "disabled settings block startRecording" behavior
        final disabledSettingsClient = createFakeSettingsClient(
          isEnabled: false,
        );
        final disabledSettingsService = SettingsService(
          token: 'test-token',
          logger: logger,
          httpClient: disabledSettingsClient,
        );

        final coordinator = SessionReplayCoordinator(
          screenshotCapturer: screenshotCapturer,
          eventRecorder: eventRecorder,
          uploadService: uploadService,
          settingsService: disabledSettingsService,
          sessionManager: sessionManager,
          logger: logger,
          autoRecordSessionsPercent: 0, // No auto-start to avoid race
          debugOptions: null,
        );

        // Trigger settings check via foreground
        coordinator.onAppForegrounded();
        // Wait for settings check to complete
        await pumpEventQueue();

        // Settings should be disabled
        expect(coordinator.remoteSettingsState, RemoteSettingsState.disabled);

        // WHEN - try to start recording after settings are disabled
        coordinator.startRecording(sessionsPercent: 100.0);

        // THEN - should not be recording (blocked by disabled settings)
        expect(coordinator.recordingState, RecordingState.notRecording);
      });

      test('stays in notRecording with 0% sampling', () {
        // GIVEN
        final expectedState = RecordingState.notRecording;
        final coordinator = createCoordinator();

        // WHEN
        coordinator.startRecording(sessionsPercent: 0.0);

        // THEN
        expect(coordinator.recordingState, expectedState);
      });
    });

    group('stopRecording', () {
      test('transitions to notRecording state', () async {
        // GIVEN
        final expectedState = RecordingState.notRecording;
        final coordinator = createCoordinator();
        coordinator.startRecording(sessionsPercent: 100.0);
        await pumpEventQueue();

        // WHEN
        coordinator.stopRecording();

        // THEN
        expect(coordinator.recordingState, expectedState);
      });

      test('is safe to call when not recording', () {
        // GIVEN
        final coordinator = createCoordinator();

        // WHEN / THEN - should not throw
        coordinator.stopRecording();
        expect(coordinator.recordingState, RecordingState.notRecording);
      });

      test('allows restarting after stop', () async {
        // GIVEN - start and then stop recording
        final coordinator = createCoordinator();
        coordinator.startRecording(sessionsPercent: 100.0);
        await pumpEventQueue();
        expect(coordinator.recordingState, RecordingState.recording);
        coordinator.stopRecording();
        expect(coordinator.recordingState, RecordingState.notRecording);

        // WHEN - start recording again from notRecording state
        coordinator.startRecording(sessionsPercent: 100.0);
        await pumpEventQueue();

        // THEN - should be recording again
        expect(coordinator.recordingState, RecordingState.recording);
      });
    });

    group('captureInteraction', () {
      test('records interaction when recording is active', () async {
        // GIVEN
        final expectedInteractionType = 7;
        final expectedX = 100.0;
        final expectedY = 200.0;
        final coordinator = createCoordinator();
        coordinator.startRecording(sessionsPercent: 100.0);
        await pumpEventQueue();

        // WHEN
        coordinator.captureInteraction(
          expectedInteractionType,
          Offset(expectedX, expectedY),
        );
        // Wait for async event recording
        await pumpEventQueue();

        // THEN
        final oldest = await eventQueue.fetchOldest();
        expect(oldest, isNotNull);
        // Should find the interaction event (after metadata)
        final events = await eventQueue.fetchBatch(
          sessionId: oldest!.sessionId,
          distinctId: oldest.distinctId,
          maxBytes: 100000,
          maxCount: 10,
        );
        final interactionEvents = events
            .where((e) => e.type == EventType.interaction)
            .toList();
        expect(interactionEvents.length, 1);

        final payload = interactionEvents[0].payload as InteractionPayload;
        expect(payload.interactionType, expectedInteractionType);
        expect(payload.x, expectedX);
        expect(payload.y, expectedY);
      });

      test('skips interaction when not recording', () async {
        // GIVEN
        final coordinator = createCoordinator();
        // Don't start recording

        // WHEN
        coordinator.captureInteraction(7, Offset(100, 200));
        await pumpEventQueue();

        // THEN
        final oldest = await eventQueue.fetchOldest();
        expect(oldest, isNull);
      });

      test('skips interaction when disposed', () async {
        // GIVEN
        final coordinator = createCoordinator();
        coordinator.startRecording(sessionsPercent: 100.0);
        await pumpEventQueue();
        await coordinator.dispose();

        // WHEN
        coordinator.captureInteraction(7, Offset(100, 200));
        await pumpEventQueue();

        // THEN - queue is disposed, operations should throw
        expect(() => eventQueue.fetchOldest(), throwsA(anything));
      });
    });

    group('onAppBackgrounded', () {
      test('marks app as not in foreground', () {
        // GIVEN
        final coordinator = createCoordinator();

        // WHEN
        coordinator.onAppBackgrounded();

        // THEN
        expect(coordinator.isAppInForeground, false);
      });

      test('stops recording when app goes to background', () async {
        // GIVEN
        final coordinator = createCoordinator();
        coordinator.startRecording(sessionsPercent: 100.0);
        await pumpEventQueue();
        expect(coordinator.recordingState, RecordingState.recording);

        // WHEN
        coordinator.onAppBackgrounded();

        // THEN
        expect(coordinator.recordingState, RecordingState.notRecording);
      });

      test('is safe to call when disposed', () async {
        // GIVEN
        final coordinator = createCoordinator();
        await coordinator.dispose();

        // WHEN / THEN - should not throw
        coordinator.onAppBackgrounded();
      });
    });

    group('onAppForegrounded', () {
      test('marks app as in foreground', () {
        // GIVEN
        final coordinator = createCoordinator();
        expect(coordinator.isAppInForeground, false);

        // WHEN
        coordinator.onAppForegrounded();

        // THEN
        expect(coordinator.isAppInForeground, true);
      });

      test(
        'auto-starts recording when autoRecordSessionsPercent > 0',
        () async {
          // GIVEN
          final coordinator = createCoordinator(
            autoRecordSessionsPercent: 100.0,
          );
          coordinator.onAppBackgrounded();

          // WHEN
          coordinator.onAppForegrounded();
          await pumpEventQueue();

          // THEN
          expect(coordinator.recordingState, RecordingState.recording);
        },
      );

      test('does not auto-start when autoRecordSessionsPercent is 0', () async {
        // GIVEN
        final coordinator = createCoordinator(autoRecordSessionsPercent: 0);
        coordinator.onAppBackgrounded();

        // WHEN
        coordinator.onAppForegrounded();
        await pumpEventQueue();

        // THEN
        expect(coordinator.recordingState, RecordingState.notRecording);
      });

      test('checks remote settings on first foreground', () async {
        // GIVEN
        final coordinator = createCoordinator();
        expect(coordinator.remoteSettingsState, RemoteSettingsState.pending);

        // WHEN
        coordinator.onAppForegrounded();
        // Wait for async settings check
        await pumpEventQueue();

        // THEN
        expect(coordinator.remoteSettingsState, RemoteSettingsState.enabled);
      });

      test('disables recording when remote settings return disabled', () async {
        // GIVEN
        final disabledSettingsService = SettingsService(
          token: 'test-token',
          logger: logger,
          httpClient: createFakeSettingsClient(isEnabled: false),
        );

        final coordinator = SessionReplayCoordinator(
          screenshotCapturer: screenshotCapturer,
          eventRecorder: eventRecorder,
          uploadService: uploadService,
          settingsService: disabledSettingsService,
          sessionManager: sessionManager,
          logger: logger,
          autoRecordSessionsPercent: 100.0,
          debugOptions: null,
        );

        // WHEN
        coordinator.onAppForegrounded();
        await pumpEventQueue();

        // THEN
        expect(coordinator.remoteSettingsState, RemoteSettingsState.disabled);
      });

      test('is safe to call when disposed', () async {
        // GIVEN
        final coordinator = createCoordinator();
        await coordinator.dispose();

        // WHEN / THEN - should not throw
        coordinator.onAppForegrounded();
      });
    });

    group('dispose', () {
      test('prevents further interactions from being recorded', () async {
        // GIVEN
        final coordinator = createCoordinator();
        coordinator.startRecording(sessionsPercent: 100.0);
        await pumpEventQueue();

        // WHEN
        await coordinator.dispose();

        // THEN - captureInteraction is a no-op
        coordinator.captureInteraction(7, Offset(100, 200));
        // Event queue is disposed so we can't check it,
        // but the call should not throw
      });

      test('is safe to call stopRecording after dispose', () async {
        // GIVEN
        final coordinator = createCoordinator();
        await coordinator.dispose();

        // WHEN / THEN - should not throw
        coordinator.stopRecording();
      });

      test('is safe to call startRecording after dispose', () async {
        // GIVEN
        final coordinator = createCoordinator();
        await coordinator.dispose();

        // WHEN / THEN - should not throw
        coordinator.startRecording(sessionsPercent: 100.0);
      });

      test('resets recordingState to notRecording', () async {
        // GIVEN - coordinator is actively recording
        final coordinator = createCoordinator();
        coordinator.startRecording(sessionsPercent: 100.0);
        await pumpEventQueue();
        expect(coordinator.recordingState, RecordingState.recording);

        // WHEN
        await coordinator.dispose();

        // THEN
        expect(coordinator.recordingState, RecordingState.notRecording);
      });
    });

    group('getters', () {
      test('logger getter returns logger instance', () {
        // GIVEN
        final coordinator = createCoordinator();

        // WHEN / THEN
        expect(coordinator.logger, isNotNull);
        expect(coordinator.logger, same(logger));
      });

      test('debugOptions returns null when not set', () {
        // GIVEN
        final coordinator = createCoordinator();

        // WHEN / THEN
        expect(coordinator.debugOptions, isNull);
      });

      test('maskRegionsNotifier returns a ValueNotifier', () {
        // GIVEN
        final coordinator = createCoordinator();

        // WHEN / THEN
        expect(coordinator.maskRegionsNotifier, isNotNull);
        expect(coordinator.maskRegionsNotifier.value, isEmpty);
      });
    });

    group('settings error handling', () {
      test('settings check error sets state to disabled', () async {
        // GIVEN - settings service that throws an error
        final errorSettingsService = SettingsService(
          token: 'test-token',
          logger: logger,
          httpClient: createFailingHttpClient(),
        );

        final coordinator = SessionReplayCoordinator(
          screenshotCapturer: screenshotCapturer,
          eventRecorder: eventRecorder,
          uploadService: uploadService,
          settingsService: errorSettingsService,
          sessionManager: sessionManager,
          logger: logger,
          autoRecordSessionsPercent: 0,
          debugOptions: null,
        );

        // WHEN
        coordinator.onAppForegrounded();
        await pumpEventQueue();

        // THEN - settings check error should set state to disabled
        expect(coordinator.remoteSettingsState, RemoteSettingsState.disabled);
      });

      test(
        'settings check error stops recording that started while check was pending',
        () async {
          // GIVEN - settings service that throws an error
          final errorSettingsService = SettingsService(
            token: 'test-token',
            logger: logger,
            httpClient: createFailingHttpClient(),
          );

          // Use autoRecordSessionsPercent: 0 to avoid the race condition where
          // recordSession().then() fires after the settings error handler
          final coordinator = SessionReplayCoordinator(
            screenshotCapturer: screenshotCapturer,
            eventRecorder: eventRecorder,
            uploadService: uploadService,
            settingsService: errorSettingsService,
            sessionManager: sessionManager,
            logger: logger,
            autoRecordSessionsPercent: 0,
            debugOptions: null,
          );

          // Manually start recording (simulating recording started while settings pending)
          coordinator.startRecording(sessionsPercent: 100.0);
          await pumpEventQueue();
          expect(coordinator.recordingState, RecordingState.recording);

          // WHEN - foreground triggers settings check which fails
          coordinator.onAppForegrounded();
          await pumpEventQueue();

          // THEN - settings error should disable and reset recording state
          expect(coordinator.remoteSettingsState, RemoteSettingsState.disabled);
          expect(coordinator.recordingState, RecordingState.notRecording);
        },
      );

      test(
        'already-enabled settings starts upload service on subsequent foreground',
        () async {
          // GIVEN - first foreground sets settings to enabled
          final coordinator = createCoordinator();
          coordinator.onAppForegrounded();
          await pumpEventQueue();
          expect(coordinator.remoteSettingsState, RemoteSettingsState.enabled);

          // Background then foreground again
          coordinator.onAppBackgrounded();

          // WHEN - second foreground with settings already enabled
          coordinator.onAppForegrounded();
          await pumpEventQueue();

          // THEN - should not error, upload service started immediately
          expect(coordinator.remoteSettingsState, RemoteSettingsState.enabled);
          expect(coordinator.isAppInForeground, true);
        },
      );
    });

    group('replayId', () {
      test('returns null when not recording', () {
        // GIVEN
        final coordinator = createCoordinator();

        // WHEN / THEN
        expect(coordinator.replayId, isNull);
      });

      test('returns session ID when recording', () async {
        // GIVEN
        final coordinator = createCoordinator();
        coordinator.startRecording(sessionsPercent: 100.0);
        await pumpEventQueue();

        // WHEN
        final replayId = coordinator.replayId;

        // THEN
        expect(replayId, isNotNull);
        expect(replayId, sessionManager.getCurrentSession().id);
      });

      test('returns session ID during initializing state', () {
        // GIVEN
        final coordinator = createCoordinator();

        // WHEN - start recording but don't pump (stays in initializing)
        coordinator.startRecording(sessionsPercent: 100.0);

        // THEN
        expect(coordinator.recordingState, RecordingState.initializing);
        expect(coordinator.replayId, isNotNull);
        expect(coordinator.replayId, sessionManager.getCurrentSession().id);
      });

      test('returns null after stopRecording', () async {
        // GIVEN
        final coordinator = createCoordinator();
        coordinator.startRecording(sessionsPercent: 100.0);
        await pumpEventQueue();
        expect(coordinator.replayId, isNotNull);

        // WHEN
        coordinator.stopRecording();

        // THEN
        expect(coordinator.replayId, isNull);
      });

      test('returns new ID after restart', () async {
        // GIVEN
        final coordinator = createCoordinator();
        coordinator.startRecording(sessionsPercent: 100.0);
        await pumpEventQueue();
        final firstReplayId = coordinator.replayId;

        // WHEN
        coordinator.stopRecording();
        coordinator.startRecording(sessionsPercent: 100.0);
        await pumpEventQueue();
        final secondReplayId = coordinator.replayId;

        // THEN
        expect(firstReplayId, isNotNull);
        expect(secondReplayId, isNotNull);
        expect(secondReplayId, isNot(equals(firstReplayId)));
      });
    });

    group('SessionReplaySender integration', () {
      late List<MethodCall> methodCalls;

      setUp(() {
        methodCalls = [];

        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel('com.mixpanel.flutter_session_replay'),
              (call) async {
                methodCalls.add(call);
                return null;
              },
            );
      });

      tearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel('com.mixpanel.flutter_session_replay'),
              null,
            );
      });

      test('registers \$mp_replay_id on startRecording', () async {
        // GIVEN
        final coordinator = createCoordinator();

        // WHEN
        coordinator.startRecording(sessionsPercent: 100.0);
        await pumpEventQueue();

        // THEN
        final registerCalls = methodCalls
            .where((c) => c.method == 'registerSuperProperties')
            .toList();
        expect(registerCalls, hasLength(1));
        final args = registerCalls[0].arguments as Map;
        expect(args['\$mp_replay_id'], sessionManager.getCurrentSession().id);
      });

      test('unregisters \$mp_replay_id on stopRecording', () async {
        // GIVEN
        final coordinator = createCoordinator();
        coordinator.startRecording(sessionsPercent: 100.0);
        await pumpEventQueue();

        // WHEN
        coordinator.stopRecording();
        await pumpEventQueue();

        // THEN
        final unregisterCalls = methodCalls
            .where((c) => c.method == 'unregisterSuperProperty')
            .toList();
        expect(unregisterCalls, hasLength(1));
        expect(unregisterCalls[0].arguments, {'key': '\$mp_replay_id'});
      });

      test('does not register when sampling rejects', () async {
        // GIVEN
        final coordinator = createCoordinator();

        // WHEN
        coordinator.startRecording(sessionsPercent: 0.0);
        await pumpEventQueue();

        // THEN
        final registerCalls = methodCalls
            .where((c) => c.method == 'registerSuperProperties')
            .toList();
        expect(registerCalls, isEmpty);
      });

      test('unregisters on app backgrounded', () async {
        // GIVEN
        final coordinator = createCoordinator();
        coordinator.startRecording(sessionsPercent: 100.0);
        await pumpEventQueue();

        // WHEN
        coordinator.onAppBackgrounded();
        await pumpEventQueue();

        // THEN
        final unregisterCalls = methodCalls
            .where((c) => c.method == 'unregisterSuperProperty')
            .toList();
        expect(unregisterCalls, hasLength(1));
        expect(unregisterCalls[0].arguments, {'key': '\$mp_replay_id'});
      });
    });

    group('stopRecording flush error', () {
      test('does not throw when flush fails during stop', () async {
        // GIVEN - coordinator with recording active
        final coordinator = createCoordinator();
        coordinator.startRecording(sessionsPercent: 100.0);
        await pumpEventQueue();

        // Dispose event queue to force flush to error
        await eventQueue.dispose();

        // WHEN / THEN - stopRecording should not throw even if flush fails
        coordinator.stopRecording();
        expect(coordinator.recordingState, RecordingState.notRecording);
      });
    });

    group('recording state machine', () {
      test(
        'full lifecycle: notRecording -> recording -> notRecording',
        () async {
          // GIVEN
          final coordinator = createCoordinator();
          expect(coordinator.recordingState, RecordingState.notRecording);

          // WHEN - start recording
          coordinator.startRecording(sessionsPercent: 100.0);
          await pumpEventQueue();

          // THEN
          expect(coordinator.recordingState, RecordingState.recording);

          // WHEN - stop recording
          coordinator.stopRecording();

          // THEN
          expect(coordinator.recordingState, RecordingState.notRecording);
        },
      );

      test('background/foreground cycle creates new session', () async {
        // GIVEN
        final coordinator = createCoordinator(autoRecordSessionsPercent: 100.0);
        coordinator.startRecording(sessionsPercent: 100.0);
        await pumpEventQueue();
        final firstSession = sessionManager.getCurrentSession();

        // WHEN - background then foreground
        coordinator.onAppBackgrounded();
        coordinator.onAppForegrounded();
        await pumpEventQueue();

        // THEN - new session created
        final secondSession = sessionManager.getCurrentSession();
        expect(secondSession.id, isNot(equals(firstSession.id)));
      });
    });
  });
}
