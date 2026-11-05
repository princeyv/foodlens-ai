import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/navigation/route_observer.dart';
import 'core/network/supabase_client.dart';
import 'core/theme/app_theme.dart';
import 'features/camera/presentation/camera_screen.dart';
import 'features/nutrition/data/nutrition_repository.dart';
import 'features/nutrition/presentation/ingredient_swiper_screen.dart';
import 'screens/dashboard_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Load environment variables from .env asset.
  await dotenv.load(fileName: '.env');

  // Initialize Supabase with credentials from .env.
  await SupabaseClientProvider.init();

  // Initialize offline-to-online connection listener and flush pending meals.
  NutritionRepository.instance.initializeConnectionListener();
  unawaited(NutritionRepository.instance.flushPendingMealQueue());

  runApp(
    // Wrap the entire app in ProviderScope for Riverpod state
    // management (§1.2).
    const ProviderScope(
      child: CoreNutritionApp(),
    ),
  );
}

/// Root application widget.
///
/// Uses a dark theme with the camera screen as the home page,
/// reflecting the camera-first design philosophy.
class CoreNutritionApp extends StatelessWidget {
  const CoreNutritionApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'FoodLens AI',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.darkTheme,
      navigatorObservers: [routeObserver],
      initialRoute: '/',
      routes: {
        '/': (context) => const DashboardScreen(),
        '/camera': (context) => const CameraScreen(),
        '/nutrition/swiper': (context) => const IngredientSwiperScreen(),
      },
    );
  }
}
