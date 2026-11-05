import 'ingredient_item.dart';

/// The complete result of a Gemini Vision meal photo analysis.
///
/// Contains the overall [mealName], a list of identified
/// [IngredientItem]s with macro breakdowns, [estimatedCalories],
/// and an [overallHealthScore].
class MealAnalysis {
  final String mealName;
  final List<IngredientItem> items;
  final double estimatedCalories;
  final double overallHealthScore;

  const MealAnalysis({
    required this.mealName,
    required this.items,
    required this.estimatedCalories,
    required this.overallHealthScore,
  });

  MealAnalysis copyWith({
    String? mealName,
    List<IngredientItem>? items,
    double? estimatedCalories,
    double? overallHealthScore,
  }) {
    return MealAnalysis(
      mealName: mealName ?? this.mealName,
      items: items ?? this.items,
      estimatedCalories: estimatedCalories ?? this.estimatedCalories,
      overallHealthScore: overallHealthScore ?? this.overallHealthScore,
    );
  }

  factory MealAnalysis.fromJson(Map<String, dynamic> json) {
    final itemsList = (json['items'] as List<dynamic>?)
            ?.map((e) => IngredientItem.fromJson(e as Map<String, dynamic>))
            .toList() ??
        <IngredientItem>[];

    // Compute estimated calories if not explicitly provided
    final calculatedCalories = itemsList.fold<double>(
      0.0,
      (sum, item) => sum + (4 * item.protein) + (4 * item.carbs) + (9 * item.fat),
    );

    final estCalories = (json['estimated_calories'] as num?)?.toDouble() ??
        (json['estimatedCalories'] as num?)?.toDouble() ??
        calculatedCalories;

    final healthScore = (json['overall_health_score'] as num?)?.toDouble() ??
        (json['overallHealthScore'] as num?)?.toDouble() ??
        8.5;

    return MealAnalysis(
      mealName: json['meal_name'] as String? ??
          json['mealName'] as String? ??
          'Meal',
      items: itemsList,
      estimatedCalories: estCalories,
      overallHealthScore: healthScore,
    );
  }

  Map<String, dynamic> toJson() => {
    'meal_name': mealName,
    'items': items.map((e) => e.toJson()).toList(),
    'estimated_calories': estimatedCalories,
    'overall_health_score': overallHealthScore,
  };

  /// Factory for a realistic clinical athletic demo meal:
  /// "Grilled Salmon & Quinoa Bowl" with 4 items:
  /// Atlantic Salmon 200g, Quinoa 150g, Steamed Broccoli 100g, Olive Oil Dressing 15g.
  /// Used for zero-latency video grading and offline fallback.
  static MealAnalysis createDemoMeal() {
    return const MealAnalysis(
      mealName: 'Grilled Salmon & Quinoa Bowl',
      items: [
        IngredientItem(
          name: 'Atlantic Salmon',
          weightGrams: 200,
          protein: 40.0,
          carbs: 0.0,
          fat: 26.0,
          fiber: 0.0,
          confidence: 0.95,
        ),
        IngredientItem(
          name: 'Quinoa',
          weightGrams: 150,
          protein: 6.5,
          carbs: 32.0,
          fat: 2.9,
          fiber: 4.2,
          confidence: 0.95,
        ),
        IngredientItem(
          name: 'Steamed Broccoli',
          weightGrams: 100,
          protein: 2.8,
          carbs: 7.0,
          fat: 0.4,
          fiber: 2.6,
          confidence: 0.95,
        ),
        IngredientItem(
          name: 'Olive Oil Dressing',
          weightGrams: 15,
          protein: 0.0,
          carbs: 0.0,
          fat: 14.0,
          fiber: 0.0,
          confidence: 0.95,
        ),
      ],
      estimatedCalories: 743.0,
      overallHealthScore: 95.0,
    );
  }
}
