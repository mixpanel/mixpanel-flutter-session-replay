/// Parsed SDK config from the remote settings endpoint.
class SdkConfig {
  final double? recordSessionsPercent;

  const SdkConfig({this.recordSessionsPercent});

  factory SdkConfig.fromJson(Map<String, dynamic> json) {
    return SdkConfig(
      recordSessionsPercent: (json['record_sessions_percent'] as num?)
          ?.toDouble(),
    );
  }

  Map<String, dynamic> toJson() => {
    if (recordSessionsPercent != null)
      'record_sessions_percent': recordSessionsPercent,
  };
}
