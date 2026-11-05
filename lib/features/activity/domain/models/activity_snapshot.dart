/// A point-in-time snapshot of the user's activity sensor data.
///
/// Combines step counts from the hardware pedometer coprocessor
/// with optional GPS-derived distance metrics.
class ActivitySnapshot {
  /// Total step count from the pedometer since the last device reboot.
  final int totalSteps;

  /// Steps recorded during the current session (since app launch).
  final int sessionSteps;

  /// Current latitude from GPS (null if location unavailable).
  final double? latitude;

  /// Current longitude from GPS (null if location unavailable).
  final double? longitude;

  /// Cumulative distance traveled in meters during this session.
  final double sessionDistanceMeters;

  /// Timestamp of this snapshot.
  final DateTime timestamp;

  const ActivitySnapshot({
    required this.totalSteps,
    required this.sessionSteps,
    this.latitude,
    this.longitude,
    this.sessionDistanceMeters = 0.0,
    required this.timestamp,
  });

  ActivitySnapshot copyWith({
    int? totalSteps,
    int? sessionSteps,
    double? latitude,
    double? longitude,
    double? sessionDistanceMeters,
    DateTime? timestamp,
  }) {
    return ActivitySnapshot(
      totalSteps: totalSteps ?? this.totalSteps,
      sessionSteps: sessionSteps ?? this.sessionSteps,
      latitude: latitude ?? this.latitude,
      longitude: longitude ?? this.longitude,
      sessionDistanceMeters:
          sessionDistanceMeters ?? this.sessionDistanceMeters,
      timestamp: timestamp ?? this.timestamp,
    );
  }

  factory ActivitySnapshot.fromJson(Map<String, dynamic> json) {
    return ActivitySnapshot(
      totalSteps: json['totalSteps'] as int? ?? 0,
      sessionSteps: json['sessionSteps'] as int? ?? 0,
      latitude: (json['latitude'] as num?)?.toDouble(),
      longitude: (json['longitude'] as num?)?.toDouble(),
      sessionDistanceMeters:
          (json['sessionDistanceMeters'] as num?)?.toDouble() ?? 0.0,
      timestamp: json['timestamp'] != null
          ? DateTime.parse(json['timestamp'] as String)
          : DateTime.now(),
    );
  }

  Map<String, dynamic> toJson() => {
    'totalSteps': totalSteps,
    'sessionSteps': sessionSteps,
    'latitude': latitude,
    'longitude': longitude,
    'sessionDistanceMeters': sessionDistanceMeters,
    'timestamp': timestamp.toIso8601String(),
  };
}
