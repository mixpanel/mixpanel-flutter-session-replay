import 'models/configuration.dart';
import 'models/debug_overlay_colors.dart';

/// Configuration options for Mixpanel Session Replay
///
/// Provides sensible defaults for all platforms with optional platform-specific
/// configuration via [platformOptions].
///
/// Example:
/// ```dart
/// SessionReplayOptions(
///   // Global settings (apply to all platforms)
///   logLevel: LogLevel.debug,
///   // Platform-specific options
///   platformOptions: PlatformOptions(
///     mobile: MobileOptions(wifiOnly: true),
///   ),
/// )
/// ```
class SessionReplayOptions {
  const SessionReplayOptions({
    this.autoMaskedViews = const {AutoMaskedView.text, AutoMaskedView.image},
    this.flushInterval = const Duration(seconds: 10),
    this.autoRecordSessionsPercent = 100.0,
    this.remoteSettingsMode = RemoteSettingsMode.disabled,
    this.storageQuotaMB = 50,
    this.logLevel = LogLevel.none,
    this.platformOptions = const PlatformOptions(),
    this.debugOptions,
  }) : assert(
         autoRecordSessionsPercent >= 0 && autoRecordSessionsPercent <= 100,
         'autoRecordSessionsPercent must be between 0 and 100',
       );

  /// View types to automatically mask for privacy
  final Set<AutoMaskedView> autoMaskedViews;

  /// Batch upload interval (default: 10 seconds)
  ///
  /// Resolution rules applied at flush time:
  /// - Zero or negative: disables automatic flushing entirely
  /// - Greater than zero but less than 1 second: resolves to 1 second
  /// - 1 second or greater: respected as-is
  final Duration flushInterval;

  /// Percentage of sessions to automatically record, 0-100 (default: 100.0)
  final double autoRecordSessionsPercent;

  /// Controls how remote configuration settings are fetched and applied.
  ///
  /// Remote settings allow server-side control over session replay parameters
  /// (e.g., sampling rate) without requiring an app update.
  ///
  /// - [RemoteSettingsMode.disabled] (default): Ignores remote SDK config values.
  /// - [RemoteSettingsMode.strict]: Requires successful fetch; no replays sent on failure.
  /// - [RemoteSettingsMode.fallback]: Uses remote config when available, falls back to cache or local config.
  final RemoteSettingsMode remoteSettingsMode;

  /// Maximum MB for event queue (default: 50)
  final int storageQuotaMB;

  /// Log level for SDK logging (default: none)
  final LogLevel logLevel;

  /// Platform-specific configuration options
  final PlatformOptions platformOptions;

  /// DEBUG: Debug configuration options
  ///
  /// When non-null, enables debug features such as mask overlay visualization.
  ///
  /// When null (default), all debug features are disabled.
  ///
  /// Example:
  /// ```dart
  /// debugOptions: DebugOptions() // Enabled with defaults
  /// debugOptions: null // All debug features disabled
  /// ```
  final DebugOptions? debugOptions;
}
