import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Tracks the list of file paths for photos captured during the
/// current camera session.
///
/// Paths are appended via [addCapture] and can be cleared with
/// [reset] when starting a new session.
class CapturedPhotoPathsNotifier extends StateNotifier<List<String>> {
  CapturedPhotoPathsNotifier() : super(const []);

  /// Add a new captured photo file path.
  void addCapture(String path) {
    state = [...state, path];
  }

  /// Remove a specific capture by path.
  void removeCapture(String path) {
    state = state.where((p) => p != path).toList();
  }

  /// Clear all captures (e.g. after analysis submission).
  void reset() {
    state = const [];
  }
}

/// Provider managing captured photo file paths in the active camera session.
final capturedPhotoPathsProvider =
    StateNotifierProvider<CapturedPhotoPathsNotifier, List<String>>((ref) {
  return CapturedPhotoPathsNotifier();
});

/// Tracks whether photo analysis is currently in progress.
class IsAnalyzingNotifier extends StateNotifier<bool> {
  IsAnalyzingNotifier() : super(false);

  void setAnalyzing(bool value) {
    state = value;
  }
}

/// Provider indicating if photo analysis is executing.
final isAnalyzingProvider =
    StateNotifierProvider<IsAnalyzingNotifier, bool>((ref) {
  return IsAnalyzingNotifier();
});
