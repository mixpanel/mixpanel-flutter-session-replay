import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:mixpanel_flutter_session_replay/src/internal/upload/settings_service.dart';
import 'package:mixpanel_flutter_session_replay/src/internal/logger.dart';
import 'package:mixpanel_flutter_session_replay/src/models/configuration.dart';

import 'helpers/fake_http_client.dart';

void main() {
  group('SettingsService', () {
    final testToken = 'test-token-123';

    group('checkRecordingEnabled', () {
      test(
        'returns true when server responds with recording enabled',
        () async {
          // GIVEN
          final expectedResult = true;
          final httpClient = createFakeSettingsClient(isEnabled: true);
          final service = SettingsService(
            token: testToken,
            logger: MixpanelLogger(LogLevel.none),
            httpClient: httpClient,
          );

          // WHEN
          final result = await service.checkRecordingEnabled();

          // THEN
          expect(result, expectedResult);
        },
      );

      test(
        'returns false when server responds with recording disabled',
        () async {
          // GIVEN
          final expectedResult = false;
          final httpClient = createFakeSettingsClient(isEnabled: false);
          final service = SettingsService(
            token: testToken,
            logger: MixpanelLogger(LogLevel.none),
            httpClient: httpClient,
          );

          // WHEN
          final result = await service.checkRecordingEnabled();

          // THEN
          expect(result, expectedResult);
        },
      );

      test('returns cached result on subsequent calls', () async {
        // GIVEN
        var requestCount = 0;
        final httpClient = http_testing.MockClient((request) async {
          requestCount++;
          return http.Response(
            jsonEncode({
              'recording': {'is_enabled': true},
            }),
            200,
          );
        });

        final service = SettingsService(
          token: testToken,
          logger: MixpanelLogger(LogLevel.none),
          httpClient: httpClient,
        );

        // WHEN
        await service.checkRecordingEnabled();
        await service.checkRecordingEnabled();
        await service.checkRecordingEnabled();

        // THEN
        expect(requestCount, 1);
      });

      test('defaults to disabled on network error', () async {
        // GIVEN
        final expectedResult = false;
        final httpClient = createFailingHttpClient();
        final service = SettingsService(
          token: testToken,
          logger: MixpanelLogger(LogLevel.none),
          httpClient: httpClient,
        );

        // WHEN
        final result = await service.checkRecordingEnabled();

        // THEN
        expect(result, expectedResult);
      });

      test('defaults to disabled on non-200 status code', () async {
        // GIVEN
        final expectedResult = false;
        final httpClient = createFakeHttpClient(statusCode: 500);
        final service = SettingsService(
          token: testToken,
          logger: MixpanelLogger(LogLevel.none),
          httpClient: httpClient,
        );

        // WHEN
        final result = await service.checkRecordingEnabled();

        // THEN
        expect(result, expectedResult);
      });

      test(
        'defaults to enabled when response omits is_enabled field',
        () async {
          // GIVEN
          final expectedResult = true;
          final httpClient = http_testing.MockClient((request) async {
            return http.Response(jsonEncode({'recording': {}}), 200);
          });

          final service = SettingsService(
            token: testToken,
            logger: MixpanelLogger(LogLevel.none),
            httpClient: httpClient,
          );

          // WHEN
          final result = await service.checkRecordingEnabled();

          // THEN
          expect(result, expectedResult);
        },
      );

      test('deduplicates concurrent requests', () async {
        // GIVEN
        var requestCount = 0;
        final completer = Completer<http.Response>();
        final httpClient = http_testing.MockClient((request) {
          requestCount++;
          return completer.future;
        });
        final response = http.Response(
          jsonEncode({
            'recording': {'is_enabled': true},
          }),
          200,
        );

        final service = SettingsService(
          token: testToken,
          logger: MixpanelLogger(LogLevel.none),
          httpClient: httpClient,
        );

        // WHEN - launch multiple concurrent checks, then complete the request
        final future = Future.wait([
          service.checkRecordingEnabled(),
          service.checkRecordingEnabled(),
          service.checkRecordingEnabled(),
        ]);
        completer.complete(response);
        final results = await future;

        // THEN - only one network request, all get same result
        expect(requestCount, 1);
        expect(results, [true, true, true]);
      });
    });

    test('sends correct endpoint, auth header, and query parameters', () async {
      // GIVEN
      final expectedCredentials = base64Encode(utf8.encode('$testToken:'));
      final expectedAuthHeader = 'Basic $expectedCredentials';

      final recorder = createRecordingHttpClient(
        statusCode: 200,
        body: jsonEncode({
          'recording': {'is_enabled': true},
        }),
      );

      final service = SettingsService(
        token: testToken,
        logger: MixpanelLogger(LogLevel.none),
        httpClient: recorder.client,
      );

      // WHEN
      await service.checkRecordingEnabled();

      // THEN
      expect(recorder.requests.length, 1);
      final request = recorder.requests[0];
      final uri = request.url;

      expect(uri.host, 'api.mixpanel.com');
      expect(uri.path, '/settings');
      expect(request.headers['Authorization'], expectedAuthHeader);
      expect(uri.queryParameters['recording'], '1');
      expect(uri.queryParameters['mp_lib'], 'flutter-sr');
      expect(uri.queryParameters['\$lib_version'], endsWith('-flutter'));
      expect(uri.queryParameters['\$os'], anyOf('Android', 'iOS', 'Mac OS X'));
    });
  });
}
