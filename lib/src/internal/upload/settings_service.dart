import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../version.dart';
import '../logger.dart';

/// Remote settings state
enum RemoteSettingsState {
  /// Settings check has not been performed yet
  pending,

  /// Settings check completed - recording is enabled
  enabled,

  /// Settings check completed - recording is disabled
  disabled,
}

/// Service for checking remote settings
///
/// This service checks if session replay recording is enabled via Mixpanel's
/// settings endpoint. The check runs once per app launch.
class SettingsService {
  final String _token;
  final MixpanelLogger _logger;
  final http.Client _httpClient;

  /// Settings endpoint
  static const String _endpoint = 'https://api.mixpanel.com/settings';

  /// Request timeout (5 seconds, matching iOS/Android)
  static const Duration _timeout = Duration(seconds: 5);

  /// Cached result from the last check
  bool? _cachedResult;

  /// Current remote settings state.
  RemoteSettingsState get remoteState => switch (_cachedResult) {
    true => RemoteSettingsState.enabled,
    false => RemoteSettingsState.disabled,
    null => RemoteSettingsState.pending,
  };

  /// Completer for in-flight settings check
  Completer<bool>? _pendingCheck;

  /// Whether this service has been disposed
  bool _isDisposed = false;

  SettingsService({
    required String token,
    required MixpanelLogger logger,
    http.Client? httpClient,
  }) : _token = token,
       _logger = logger,
       _httpClient = httpClient ?? http.Client();

  /// Check if recording is enabled via remote settings
  ///
  /// This performs a network request to Mixpanel's settings endpoint once per app launch.
  /// Returns true if recording is enabled, false if disabled.
  ///
  /// Defaults to disabled (false) if network request fails (fail closed).
  /// If a check is already in progress, waits for that check to complete.
  Future<bool> checkRecordingEnabled() async {
    // Return cached result if already checked
    if (_cachedResult != null) {
      _logger.debug(
        'Settings already checked, returning cached result: $_cachedResult',
      );
      return _cachedResult!;
    }

    // If check is already in progress, wait for it to complete
    // This prevents duplicate network requests if called multiple times
    if (_pendingCheck != null) {
      _logger.debug('Settings check already in progress, waiting...');
      return await _pendingCheck!.future;
    }

    // Create completer for this check
    _pendingCheck = Completer<bool>();

    try {
      // Make network request
      _logger.debug('Checking remote settings...');
      final isEnabled = await _makeSettingsRequest();

      _cachedResult = isEnabled;
      _logger.info('Remote settings check complete: isEnabled=$isEnabled');

      // Complete the future for any waiting callers
      _pendingCheck!.complete(isEnabled);
      return isEnabled;
    } catch (e) {
      _logger.warning('Settings check failed: $e - defaulting to disabled');
      // Default to disabled if network fails (fail closed)
      _cachedResult = false;

      // Complete the future for any waiting callers
      _pendingCheck!.complete(false);
      return false;
    } finally {
      _pendingCheck = null;
    }
  }

  /// Make network request to settings endpoint
  ///
  /// Returns true if recording is enabled, false if disabled
  Future<bool> _makeSettingsRequest() async {
    // Build request URI
    final uri = Uri.parse(_endpoint).replace(
      queryParameters: {
        'recording': '1',
        'mp_lib': 'flutter-sr',
        '\$lib_version': sdkVersion,
        '\$os': operatingSystem,
      },
    );

    // Build authorization header (Basic auth with token as username)
    final credentials = base64Encode(utf8.encode('$_token:'));
    final authHeader = 'Basic $credentials';

    _logger.debug('GET $uri');

    // Make request with timeout
    final response = await _httpClient
        .get(uri, headers: {'Authorization': authHeader})
        .timeout(_timeout);

    _logger.debug('Settings response status: ${response.statusCode}');

    if (response.statusCode == 200) {
      final json = jsonDecode(response.body) as Map<String, dynamic>;
      final recording = json['recording'] as Map<String, dynamic>?;
      final isEnabled = recording?['is_enabled'] as bool? ?? true;
      return isEnabled;
    } else {
      throw Exception(
        'Settings request failed with status ${response.statusCode}',
      );
    }
  }

  /// Dispose resources
  void dispose() {
    if (_isDisposed) return;
    _isDisposed = true;

    _httpClient.close();
  }
}
