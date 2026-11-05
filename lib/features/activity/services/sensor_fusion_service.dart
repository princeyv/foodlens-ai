import 'dart:async';

import 'package:geolocator/geolocator.dart';
import 'package:pedometer/pedometer.dart';

import '../domain/models/activity_snapshot.dart';

/// Service that fuses hardware step-counter data with distance-filtered
/// GPS tracking into a unified [ActivitySnapshot] stream.
///
/// **Sensor Fusion Strategy (§1.6)**:
/// - Steps: Uses `Pedometer.stepCountStream` which reads from the
///   hardware coprocessor — zero battery drain, runs even when the
///   app is suspended.
/// - GPS: Gates position updates behind a 25-meter distance filter
///   (`AndroidSettings(distanceFilter: 25)`) to eliminate unnecessary
///   battery consumption from continuous GPS polling.
class SensorFusionService {
  SensorFusionService._();

  static SensorFusionService? _instance;
  static SensorFusionService get instance {
    _instance ??= SensorFusionService._();
    return _instance!;
  }

  StreamSubscription<StepCount>? _stepSubscription;
  StreamSubscription<Position>? _positionSubscription;

  final _snapshotController = StreamController<ActivitySnapshot>.broadcast();

  /// Broadcast stream of fused [ActivitySnapshot]s.
  Stream<ActivitySnapshot> get snapshotStream => _snapshotController.stream;

  int _initialSteps = 0;
  int _currentTotalSteps = 0;
  bool _initialStepsRecorded = false;
  double _sessionDistance = 0.0;
  Position? _lastPosition;

  /// Start listening to both sensor streams.
  ///
  /// Call this once during app initialization after permissions
  /// have been granted.
  void startListening() {
    _listenToSteps();
    _listenToGps();
  }

  /// Stop all sensor subscriptions and clean up.
  void stopListening() {
    _stepSubscription?.cancel();
    _stepSubscription = null;
    _positionSubscription?.cancel();
    _positionSubscription = null;
  }

  /// Dispose the service entirely.
  void dispose() {
    stopListening();
    _snapshotController.close();
  }

  /// Subscribe to the hardware pedometer step count stream.
  ///
  /// The pedometer reports cumulative steps since last device reboot.
  /// We track the initial value to compute session-relative steps.
  void _listenToSteps() {
    _stepSubscription = Pedometer.stepCountStream.listen(
      (stepCount) {
        if (!_initialStepsRecorded) {
          _initialSteps = stepCount.steps;
          _initialStepsRecorded = true;
        }

        _currentTotalSteps = stepCount.steps;
        _emitSnapshot();
      },
      onError: (error) {
        // Pedometer not available on this device — degrade gracefully.
        // ignore: avoid_print
        print('SensorFusionService: Pedometer error: $error');
      },
    );
  }

  /// Subscribe to GPS position updates with a 25-meter distance filter.
  ///
  /// The distance filter ensures the GPS radio only fires when the
  /// user has moved a meaningful distance, dramatically reducing
  /// battery consumption compared to continuous tracking.
  void _listenToGps() {
    final locationSettings = AndroidSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: 25, // §1.6: 25-meter gate
      forceLocationManager: false,
    );

    _positionSubscription = Geolocator.getPositionStream(
      locationSettings: locationSettings,
    ).listen(
      (position) {
        // Accumulate distance from the last known position.
        if (_lastPosition != null) {
          final distance = Geolocator.distanceBetween(
            _lastPosition!.latitude,
            _lastPosition!.longitude,
            position.latitude,
            position.longitude,
          );
          _sessionDistance += distance;
        }

        _lastPosition = position;
        _emitSnapshot();
      },
      onError: (error) {
        // GPS not available — degrade gracefully.
        // ignore: avoid_print
        print('SensorFusionService: GPS error: $error');
      },
    );
  }

  /// Emit a fused [ActivitySnapshot] combining the latest step and
  /// GPS data.
  void _emitSnapshot() {
    final sessionSteps = _currentTotalSteps - _initialSteps;

    _snapshotController.add(
      ActivitySnapshot(
        totalSteps: _currentTotalSteps,
        sessionSteps: sessionSteps,
        latitude: _lastPosition?.latitude,
        longitude: _lastPosition?.longitude,
        sessionDistanceMeters: _sessionDistance,
        timestamp: DateTime.now(),
      ),
    );
  }
}
