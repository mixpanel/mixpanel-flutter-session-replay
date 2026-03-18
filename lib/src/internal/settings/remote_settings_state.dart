/// Remote settings state
enum RemoteSettingsState {
  /// Settings check has not been performed yet
  pending,

  /// Settings check completed - recording is enabled
  enabled,

  /// Settings check completed - recording is disabled
  disabled,
}
