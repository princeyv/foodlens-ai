import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/navigation/route_observer.dart';
import '../../../core/network/gemini_vision_service.dart';
import '../../nutrition/domain/models/meal_analysis.dart';
import '../../nutrition/providers/nutrition_providers.dart';
import '../providers/camera_providers.dart';

/// Snapchat-style camera screen with capture button and burst counter.
///
/// Implements [WidgetsBindingObserver] and [RouteAware] to manage the native
/// [CameraController] lifecycle across app state transitions and navigation:
///   - `inactive`/`paused` → dispose controller
///   - `resumed`/`didPopNext` → reset counters and reinitialize controller
class CameraScreen extends ConsumerStatefulWidget {
  const CameraScreen({super.key});

  @override
  ConsumerState<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends ConsumerState<CameraScreen>
    with WidgetsBindingObserver, RouteAware {
  CameraController? _cameraController;
  CameraController? get _controller => _cameraController;
  List<CameraDescription> _cameras = [];
  bool _isInitializing = false;
  int _burstCount = 0;
  final List<String> _capturedPaths = [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _resetCaptureState();
    _initializeCameraController();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route != null) {
      routeObserver.subscribe(this, route);
    }
  }

  @override
  void dispose() {
    routeObserver.unsubscribe(this);
    WidgetsBinding.instance.removeObserver(this);
    _disposeController();
    super.dispose();
  }

  /// RouteAware callback: triggered when returning to the camera screen
  /// after popping the top route (e.g. from ingredient swiper or review screen).
  @override
  void didPopNext() {
    debugPrint('CameraScreen: didPopNext triggered — returning to camera screen.');
    _resetCaptureState();
    _checkAndReinitializeCamera();
  }

  /// Reset the capture counter and captured photo lists to 0.
  void _resetCaptureState() {
    if (mounted) {
      setState(() {
        _burstCount = 0;
        _capturedPaths.clear();
      });
    } else {
      _burstCount = 0;
      _capturedPaths.clear();
    }
    ref.read(capturedPhotoPathsProvider.notifier).reset();
  }

  /// Checks if the camera controller is null, disposed, or not initialized,
  /// and re-initializes or resumes it so the viewfinder never remains pitch black.
  Future<void> _checkAndReinitializeCamera() async {
    final controller = _cameraController;
    if (controller == null ||
        !controller.value.isInitialized ||
        controller.value.hasError) {
      debugPrint('CameraScreen: Controller needs full re-initialization.');
      await _initializeCameraController();
    } else {
      try {
        await controller.resumePreview();
        debugPrint('CameraScreen: Camera preview resumed successfully.');
        if (mounted) setState(() {});
      } catch (e) {
        debugPrint(
          'CameraScreen: resumePreview failed ($e). Re-initializing controller...',
        );
        await _initializeCameraController();
      }
    }
  }

  /// Lifecycle management (§1.5): Cleanly dispose on inactive/paused,
  /// reinitialize on resumed.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    debugPrint('CameraScreen: didChangeAppLifecycleState: $state');
    switch (state) {
      case AppLifecycleState.inactive:
      case AppLifecycleState.paused:
        _disposeController();
      case AppLifecycleState.resumed:
        _resetCaptureState();
        _checkAndReinitializeCamera();
      case AppLifecycleState.detached:
      case AppLifecycleState.hidden:
        break;
    }
  }

  Future<void> _initializeCameraController() async {
    if (_isInitializing) return;
    _isInitializing = true;

    try {
      if (_cameraController != null) {
        final old = _cameraController;
        _cameraController = null;
        await old?.dispose();
      }

      _cameras = await availableCameras();
      if (_cameras.isEmpty) {
        debugPrint('CameraScreen: No cameras found on device.');
        _isInitializing = false;
        if (mounted) setState(() {});
        return;
      }

      // Prefer the back camera for food photography.
      final backCamera = _cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => _cameras.first,
      );

      final controller = CameraController(
        backCamera,
        ResolutionPreset.high,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.jpeg,
      );

      _cameraController = controller;
      await controller.initialize();

      if (mounted) {
        setState(() {});
      }
    } on CameraException catch (e) {
      debugPrint(
        'CameraScreen: CameraException during init: ${e.code} - ${e.description}',
      );
    } catch (e) {
      debugPrint('CameraScreen: Unexpected error during init: $e');
    } finally {
      _isInitializing = false;
    }
  }

  void _disposeController() {
    final controller = _cameraController;
    _cameraController = null;
    controller?.dispose();
    if (mounted) {
      setState(() {});
    }
  }

  /// Capture a photo and store the file path.
  ///
  /// Increments the burst counter for multi-shot support.
  /// File paths are passed (not byte arrays) to maintain memory
  /// safety (§1.4).
  Future<void> _capturePhoto() async {
    if (ref.read(isAnalyzingProvider)) return;
    if (_controller == null || !_controller!.value.isInitialized) return;
    if (_controller!.value.isTakingPicture) return;

    try {
      final xFile = await _controller!.takePicture();

      setState(() {
        _burstCount++;
        _capturedPaths.add(xFile.path);
      });

      // Notify the camera provider of the new capture.
      ref.read(capturedPhotoPathsProvider.notifier).addCapture(xFile.path);
    } on CameraException catch (e) {
      debugPrint('CameraScreen: Capture failed: ${e.code} - ${e.description}');
    }
  }

  /// Send captured photos for Gemini Vision analysis and navigate to the swiper.
  Future<void> _onConfirmCaptures() async {
    final isAnalyzing = ref.read(isAnalyzingProvider);
    if (isAnalyzing) return;

    final paths = _capturedPaths.isNotEmpty
        ? List<String>.from(_capturedPaths)
        : List<String>.from(ref.read(capturedPhotoPathsProvider));

    if (paths.isEmpty) return;

    // Show loading overlay
    ref.read(isAnalyzingProvider.notifier).setAnalyzing(true);

    try {
      final repository = ref.read(nutritionRepositoryProvider);
      final analysis = await repository.analyzeMealPhotos(paths);

      // Handle non-food detection gracefully
      if (analysis.mealName == 'No Food Detected' || analysis.items.isEmpty) {
        if (mounted) {
          ref.read(isAnalyzingProvider.notifier).setAnalyzing(false);
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'No food detected in photo. Please try again with a clear meal shot.',
              ),
              backgroundColor: Colors.orangeAccent,
              behavior: SnackBarBehavior.floating,
              duration: Duration(seconds: 3),
            ),
          );
        }
        return;
      }

      // Write resulting ingredient list to Riverpod state provider
      ref.read(mealAnalysisStateProvider.notifier).setAnalysis(analysis);

      // Reset local capture state
      setState(() {
        _burstCount = 0;
        _capturedPaths.clear();
      });
      ref.read(capturedPhotoPathsProvider.notifier).reset();

      if (!mounted) return;

      // Reset loading indicator before navigating so camera is ready upon return
      ref.read(isAnalyzingProvider.notifier).setAnalyzing(false);

      // Navigate to review ingredients screen with analysis
      await Navigator.of(context).pushNamed(
        '/nutrition/swiper',
        arguments: analysis,
      );

      // When returning from review/swiper via pop:
      if (mounted) {
        _resetCaptureState();
        await _checkAndReinitializeCamera();
      }
    } catch (e) {
      debugPrint('CameraScreen: Analysis failed: $e');
      if (mounted) {
        ref.read(isAnalyzingProvider.notifier).setAnalyzing(false);
        final String errorMessage = e is GeminiAnalysisException
            ? e.message
            : 'Failed to analyze meal: $e';

        ScaffoldMessenger.of(context).hideCurrentSnackBar();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: const Color(0xFF1E1E2E),
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 8),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(
                      Icons.error_outline,
                      color: Colors.redAccent,
                      size: 20,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        errorMessage,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: () {
                        ScaffoldMessenger.of(context).hideCurrentSnackBar();
                        _onConfirmCaptures();
                      },
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 4,
                        ),
                        foregroundColor: Colors.orangeAccent,
                      ),
                      child: const Text(
                        'Retry',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ),
                    const SizedBox(width: 8),
                    ElevatedButton(
                      onPressed: () {
                        ScaffoldMessenger.of(context).hideCurrentSnackBar();
                        _loadDemoMeal();
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF6C63FF),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 4,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                      ),
                      child: const Text(
                        'Load Sample Data',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      }
    }
  }

  /// Seamlessly loads a realistic clinical athletic demo meal
  /// ("Grilled Salmon & Quinoa Bowl") directly into the IngredientSwiperScreen,
  /// bypassing the network call completely.
  Future<void> _loadDemoMeal() async {
    final demoMeal = MealAnalysis.createDemoMeal();

    // Write resulting ingredient list to Riverpod state provider
    ref.read(mealAnalysisStateProvider.notifier).setAnalysis(demoMeal);

    _resetCaptureState();
    ref.read(isAnalyzingProvider.notifier).setAnalyzing(false);

    // Immediately navigate to review ingredients screen with demo meal
    await Navigator.of(context).pushNamed(
      '/nutrition/swiper',
      arguments: demoMeal,
    );

    // When returning from review/swiper via pop:
    if (mounted) {
      _resetCaptureState();
      await _checkAndReinitializeCamera();
    }
  }

  @override
  Widget build(BuildContext context) {
    final isAnalyzing = ref.watch(isAnalyzingProvider);
    final dailyTotals = ref.watch(dailyMacroTotalsProvider);
    final dailyCalories = dailyTotals['calories'] ?? 0.0;
    final dailyProtein = dailyTotals['protein'] ?? 0.0;
    final dailyCarbs = dailyTotals['carbs'] ?? 0.0;
    final dailyFat = dailyTotals['fat'] ?? 0.0;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // Camera preview — full screen
          if (_controller != null && _controller!.value.isInitialized)
            Positioned.fill(
              child: FittedBox(
                fit: BoxFit.cover,
                child: SizedBox(
                  width: _controller!.value.previewSize!.height,
                  height: _controller!.value.previewSize!.width,
                  child: CameraPreview(_controller!),
                ),
              ),
            )
          else
            const Center(
              child: CircularProgressIndicator(color: Colors.white),
            ),

          // Top bar — daily calorie and macro counters + burst counter + "⚡ Demo Scenario" chip
          Positioned(
            top: MediaQuery.of(context).padding.top + 12,
            left: 16,
            right: 16,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                // Left: Daily macro counters & burst counter
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (dailyCalories > 0)
                        Container(
                          margin: const EdgeInsets.only(bottom: 8),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 6,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0xA6000000),
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(
                              color: const Color(0x666C63FF),
                              width: 1,
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(
                                Icons.local_fire_department,
                                color: Colors.orangeAccent,
                                size: 16,
                              ),
                              const SizedBox(width: 4),
                              Text(
                                '${dailyCalories.round()} kcal',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 13,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Text(
                                'P: ${dailyProtein.round()}g',
                                style: const TextStyle(
                                  color: Color(0xFF4E9F3D),
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(width: 6),
                              Text(
                                'C: ${dailyCarbs.round()}g',
                                style: const TextStyle(
                                  color: Color(0xFFECA052),
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(width: 6),
                              Text(
                                'F: ${dailyFat.round()}g',
                                style: const TextStyle(
                                  color: Color(0xFFE84545),
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ),
                      if (_burstCount > 0)
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 8,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.black54,
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Text(
                            '$_burstCount photo${_burstCount == 1 ? '' : 's'}',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                // Right: "⚡ Demo Scenario" action chip
                Material(
                  color: Colors.transparent,
                  child: InkWell(
                    onTap: isAnalyzing ? null : _loadDemoMeal,
                    borderRadius: BorderRadius.circular(20),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xCC1A1A2E),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color: const Color(0xFF6C63FF),
                          width: 1.2,
                        ),
                        boxShadow: const [
                          BoxShadow(
                            color: Color(0x446C63FF),
                            blurRadius: 8,
                            offset: Offset(0, 2),
                          ),
                        ],
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            '⚡ Demo Scenario',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                              letterSpacing: 0.3,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),

          // Bottom controls — capture button + confirm
          Positioned(
            bottom: MediaQuery.of(context).padding.bottom + 32,
            left: 0,
            right: 0,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                // Spacer for symmetry
                const SizedBox(width: 64),

                // Capture button — large circular shutter
                GestureDetector(
                  onTap: isAnalyzing ? null : _capturePhoto,
                  child: Opacity(
                    opacity: isAnalyzing ? 0.4 : 1.0,
                    child: Container(
                      width: 80,
                      height: 80,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white, width: 4),
                      ),
                      child: Container(
                        margin: const EdgeInsets.all(4),
                        decoration: const BoxDecoration(
                          shape: BoxShape.circle,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
                ),

                // Confirm button — appears after first capture
                if (_burstCount > 0)
                  GestureDetector(
                    onTap: isAnalyzing ? null : _onConfirmCaptures,
                    child: Container(
                      width: 56,
                      height: 56,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: isAnalyzing
                            ? Colors.grey.shade700
                            : Colors.green.shade400,
                      ),
                      child: isAnalyzing
                          ? const Center(
                              child: SizedBox(
                                width: 24,
                                height: 24,
                                child: CircularProgressIndicator(
                                  color: Colors.white,
                                  strokeWidth: 2.5,
                                ),
                              ),
                            )
                          : const Icon(
                              Icons.check,
                              color: Colors.white,
                              size: 28,
                            ),
                    ),
                  )
                else
                  const SizedBox(width: 64),
              ],
            ),
          ),

          // Loading overlay during Gemini vision analysis
          if (isAnalyzing)
            Positioned.fill(
              child: Container(
                color: Colors.black.withValues(alpha: 0.75),
                child: Center(
                  child: Container(
                    margin: const EdgeInsets.symmetric(horizontal: 32),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 28,
                      vertical: 32,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1A1A2E).withValues(alpha: 0.95),
                      borderRadius: BorderRadius.circular(24),
                      border: Border.all(
                        color: const Color(0xFF6C63FF).withValues(alpha: 0.3),
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: const Color(0xFF6C63FF).withValues(alpha: 0.25),
                          blurRadius: 32,
                          offset: const Offset(0, 8),
                        ),
                      ],
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const SizedBox(
                          width: 52,
                          height: 52,
                          child: CircularProgressIndicator(
                            color: Color(0xFF6C63FF),
                            strokeWidth: 3.5,
                          ),
                        ),
                        const SizedBox(height: 24),
                        const Text(
                          'Analyzing Meal...',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Gemini Vision is identifying ingredients\nand calculating macros',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.7),
                            fontSize: 13,
                            height: 1.4,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
