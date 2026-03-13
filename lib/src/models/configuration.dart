/// Widget types that can be automatically masked
enum AutoMaskedView {
  /// Text widgets (Text, TextField, CupertinoTextField, EditableText)
  text,

  /// Image widgets (via RenderImage detection)
  image,
}

/// Log level for SDK logging
enum LogLevel {
  /// No logging
  none,

  /// Error messages only
  error,

  /// Warning and error messages
  warning,

  /// Info, warning, and error messages
  info,

  /// Debug and all other messages (verbose)
  debug,
}

/// Mobile-specific configuration options
///
/// These options only apply to iOS and Android platforms.
class MobileOptions {
  const MobileOptions({this.wifiOnly = true});

  /// Only upload on WiFi (default: true)
  ///
  /// When enabled, session replay data will only be uploaded when the device
  /// is connected to WiFi or Ethernet. Data is queued locally until a WiFi
  /// connection is available.
  final bool wifiOnly;
}

/// Platform-specific configuration options
///
/// Use this to configure options that only apply to specific platforms.
///
/// Example:
/// ```dart
/// SessionReplayOptions(
///   logLevel: LogLevel.debug,
///   platformOptions: PlatformOptions(
///     mobile: MobileOptions(wifiOnly: true),
///   ),
/// )
/// ```
class PlatformOptions {
  const PlatformOptions({this.mobile = const MobileOptions()});

  /// Mobile-specific options (iOS and Android)
  final MobileOptions mobile;
}
