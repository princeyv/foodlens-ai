/// A single identified ingredient from Gemini Vision analysis.
///
/// Each item carries its estimated macros (protein, carbs, fat, fiber)
/// along with a confidence score and swiped-away status for the
/// ingredient swiper UI.
class IngredientItem {
  final String name;
  final double weightGrams;
  final double protein;
  final double carbs;
  final double fat;
  final double fiber;
  final double confidence;
  final bool wasSwipedAway;

  const IngredientItem({
    required this.name,
    required this.weightGrams,
    required this.protein,
    required this.carbs,
    required this.fat,
    required this.fiber,
    required this.confidence,
    this.wasSwipedAway = false,
  });

  IngredientItem copyWith({
    String? name,
    double? weightGrams,
    double? protein,
    double? carbs,
    double? fat,
    double? fiber,
    double? confidence,
    bool? wasSwipedAway,
  }) {
    return IngredientItem(
      name: name ?? this.name,
      weightGrams: weightGrams ?? this.weightGrams,
      protein: protein ?? this.protein,
      carbs: carbs ?? this.carbs,
      fat: fat ?? this.fat,
      fiber: fiber ?? this.fiber,
      confidence: confidence ?? this.confidence,
      wasSwipedAway: wasSwipedAway ?? this.wasSwipedAway,
    );
  }

  /// Total estimated calories for this ingredient based on macronutrients:
  /// (4 * protein) + (4 * carbs) + (9 * fat).
  double get calories => (4 * protein) + (4 * carbs) + (9 * fat);

  factory IngredientItem.fromJson(Map<String, dynamic> json) {
    return IngredientItem(
      name: json['name'] as String? ?? 'Ingredient',
      weightGrams: (json['weight_grams'] as num?)?.toDouble() ??
          (json['weightGrams'] as num?)?.toDouble() ??
          (json['grams'] as num?)?.toDouble() ??
          (json['weight'] as num?)?.toDouble() ??
          0.0,
      protein: (json['protein'] as num?)?.toDouble() ??
          (json['proteins'] as num?)?.toDouble() ??
          0.0,
      carbs: (json['carbs'] as num?)?.toDouble() ??
          (json['carbohydrates'] as num?)?.toDouble() ??
          0.0,
      fat: (json['fat'] as num?)?.toDouble() ??
          (json['fats'] as num?)?.toDouble() ??
          0.0,
      fiber: (json['fiber'] as num?)?.toDouble() ??
          (json['fibers'] as num?)?.toDouble() ??
          0.0,
      confidence: (json['confidence'] as num?)?.toDouble() ?? 1.0,
      wasSwipedAway: (json['was_swiped_away'] as bool?) ??
          (json['wasSwipedAway'] as bool?) ??
          false,
    );
  }

  Map<String, dynamic> toJson() => {
    'name': name,
    'weight_grams': weightGrams,
    'protein': protein,
    'carbs': carbs,
    'fat': fat,
    'fiber': fiber,
    'confidence': confidence,
    'was_swiped_away': wasSwipedAway,
  };
}
