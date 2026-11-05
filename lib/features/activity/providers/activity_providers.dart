import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../activity/domain/models/activity_snapshot.dart';
import '../../activity/services/sensor_fusion_service.dart';

/// Provides a live stream of [ActivitySnapshot]s from the sensor
/// fusion service.
final activityStreamProvider = StreamProvider<ActivitySnapshot>((ref) {
  final service = SensorFusionService.instance;
  service.startListening();

  ref.onDispose(() {
    service.stopListening();
  });

  return service.snapshotStream;
});

/// Tracks the latest known activity snapshot for synchronous access.
class LatestActivityNotifier extends StateNotifier<ActivitySnapshot?> {
  LatestActivityNotifier(this.ref) : super(null) {
    ref.listen<AsyncValue<ActivitySnapshot>>(activityStreamProvider, (previous, next) {
      next.whenData((snapshot) {
        state = snapshot;
      });
    });
  }

  final Ref ref;
}

/// Provider managing the most recently received activity snapshot.
final latestActivityProvider =
    StateNotifierProvider<LatestActivityNotifier, ActivitySnapshot?>((ref) {
  return LatestActivityNotifier(ref);
});
