import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../nutrition/domain/models/meal_analysis.dart';
import '../data/nutrition_repository.dart';

/// Provider exposing the [NutritionRepository] instance.
final nutritionRepositoryProvider = Provider<NutritionRepository>((ref) {
  return NutritionRepository.instance;
});

/// StateNotifier that manages the current [MealAnalysis] result from Gemini Vision.
///
/// Supports optimistic updates when individual ingredients are swiped
/// away or confirmed by the user.
class MealAnalysisNotifier extends StateNotifier<MealAnalysis?> {
  MealAnalysisNotifier() : super(null);

  /// Set a new meal analysis result.
  void setAnalysis(MealAnalysis analysis) {
    state = analysis;
  }

  /// Mark a specific ingredient as swiped away (left swipe = discard).
  ///
  /// This is an optimistic state update — the UI reflects the change
  /// immediately without waiting for any backend confirmation.
  void markSwipedAway(int index) {
    if (state == null) return;
    final updatedItems = [...state!.items];
    updatedItems[index] = updatedItems[index].copyWith(wasSwipedAway: true);
    state = state!.copyWith(items: updatedItems);
  }

  /// Confirm a specific ingredient (right swipe).
  void confirmIngredient(int index) {
    if (state == null) return;
    final updatedItems = [...state!.items];
    updatedItems[index] = updatedItems[index].copyWith(wasSwipedAway: false);
    state = state!.copyWith(items: updatedItems);
  }

  /// Clear the current analysis (e.g. when returning to camera).
  void clear() {
    state = null;
  }
}

/// Provider managing the active meal analysis state.
final mealAnalysisStateProvider =
    StateNotifierProvider<MealAnalysisNotifier, MealAnalysis?>((ref) {
  return MealAnalysisNotifier();
});

/// Computes aggregated macro totals from confirmed (non-swiped) ingredients.
///
/// Derived from [mealAnalysisStateProvider] and automatically recalculates
/// whenever ingredients are swiped or confirmed.
final confirmedMacroTotalsProvider = Provider<Map<String, double>>((ref) {
  final analysis = ref.watch(mealAnalysisStateProvider);
  if (analysis == null) {
    return {
      'calories': 0.0,
      'protein': 0.0,
      'carbs': 0.0,
      'fat': 0.0,
      'fiber': 0.0,
    };
  }

  final confirmed = analysis.items.where((item) => !item.wasSwipedAway);

  double protein = 0.0;
  double carbs = 0.0;
  double fat = 0.0;
  double fiber = 0.0;

  for (final item in confirmed) {
    protein += item.protein;
    carbs += item.carbs;
    fat += item.fat;
    fiber += item.fiber;
  }

  final calories = (4 * protein) + (4 * carbs) + (9 * fat);

  return {
    'calories': calories,
    'protein': protein,
    'carbs': carbs,
    'fat': fat,
    'fiber': fiber,
  };
});

/// StateNotifier managing the local list of confirmed meal logs.
///
/// Enables offline-first functionality: meals are immediately added to local state
/// so the dashboard/counters update instantly, even if remote sync is delayed or offline.
class LoggedMealsNotifier extends StateNotifier<List<MealAnalysis>> {
  LoggedMealsNotifier() : super([]);

  /// Add a confirmed meal to the local state.
  void addMeal(MealAnalysis meal) {
    state = [meal, ...state];
  }

  /// Replace all logged meals.
  void setMeals(List<MealAnalysis> meals) {
    state = meals;
  }

  /// Clear all logged meals.
  void clear() {
    state = [];
  }
}

/// Provider managing the list of logged meals (offline-first local state).
final loggedMealsProvider =
    StateNotifierProvider<LoggedMealsNotifier, List<MealAnalysis>>((ref) {
  return LoggedMealsNotifier();
});

/// Computes cumulative daily calorie and macro totals across all confirmed [loggedMealsProvider].
///
/// Immediately recalculates whenever a meal is saved or removed.
final dailyMacroTotalsProvider = Provider<Map<String, double>>((ref) {
  final meals = ref.watch(loggedMealsProvider);

  double protein = 0.0;
  double carbs = 0.0;
  double fat = 0.0;
  double fiber = 0.0;

  for (final meal in meals) {
    final confirmed = meal.items.where((item) => !item.wasSwipedAway);
    for (final item in confirmed) {
      protein += item.protein;
      carbs += item.carbs;
      fat += item.fat;
      fiber += item.fiber;
    }
  }

  final calories = (4 * protein) + (4 * carbs) + (9 * fat);

  return {
    'calories': calories,
    'protein': protein,
    'carbs': carbs,
    'fat': fat,
    'fiber': fiber,
  };
});
