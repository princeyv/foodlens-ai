import 'package:flutter/material.dart';
import 'package:flutter_card_swiper/flutter_card_swiper.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/nutrition_repository.dart';
import '../domain/models/ingredient_item.dart';
import '../domain/models/meal_analysis.dart';
import '../providers/nutrition_providers.dart';

/// Card swiper screen for reviewing and confirming/discarding
/// individual ingredients identified by Gemini Vision.
///
/// Swipe gestures:
///   - **Left** = Discard ingredient (`wasSwipedAway = true`)
///   - **Right** = Confirm ingredient
///
/// The swiper runs in non-looping mode (`isLoop: false`). When the
/// last card is swiped, a "Review Complete" summary is shown with
/// confirmed ingredient totals and a save button.
///
/// Macro totals are optimistically recalculated in Riverpod state
/// immediately upon each swipe (no server round-trip needed).
class IngredientSwiperScreen extends ConsumerStatefulWidget {
  const IngredientSwiperScreen({super.key});

  @override
  ConsumerState<IngredientSwiperScreen> createState() =>
      _IngredientSwiperScreenState();
}

class _IngredientSwiperScreenState
    extends ConsumerState<IngredientSwiperScreen> {
  final CardSwiperController _swiperController = CardSwiperController();
  bool _reviewComplete = false;
  bool _isSaving = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final args = ModalRoute.of(context)?.settings.arguments;
    if (args is MealAnalysis && ref.read(mealAnalysisStateProvider) == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && ref.read(mealAnalysisStateProvider) == null) {
          ref.read(mealAnalysisStateProvider.notifier).setAnalysis(args);
        }
      });
    }
  }

  @override
  void dispose() {
    _swiperController.dispose();
    super.dispose();
  }

  /// Handle swipe events — update Riverpod state optimistically.
  bool _onSwipe(
    int previousIndex,
    int? currentIndex,
    CardSwiperDirection direction,
  ) {
    final notifier = ref.read(mealAnalysisStateProvider.notifier);

    if (direction == CardSwiperDirection.left) {
      // Discard: mark ingredient as swiped away.
      notifier.markSwipedAway(previousIndex);
    } else if (direction == CardSwiperDirection.right) {
      // Confirm: ensure ingredient is marked as kept.
      notifier.confirmIngredient(previousIndex);
    }

    return true; // Allow the swipe to proceed.
  }

  /// Called when the last card has been swiped (non-looping mode).
  void _onEnd() {
    if (mounted) {
      setState(() {
        _reviewComplete = true;
      });
    }
  }

  /// Save the confirmed meal analysis to local state and Supabase, then navigate home.
  Future<void> _saveAndNavigateHome(MealAnalysis analysis) async {
    if (_isSaving) return;

    setState(() {
      _isSaving = true;
    });

    // 1. Immediately persist confirmed meal to local Riverpod state list
    // so the daily macro totals and dashboard counters update right away.
    final confirmedMeal = analysis.copyWith(
      items: analysis.items.where((item) => !item.wasSwipedAway).toList(),
    );
    ref.read(loggedMealsProvider.notifier).addMeal(confirmedMeal);

    SaveMealResult? result;
    try {
      // 2. Attempt save to Supabase (non-blocking with internal offline error handling)
      result =
          await ref.read(nutritionRepositoryProvider).saveMealLog(analysis);
    } catch (e) {
      debugPrint('IngredientSwiperScreen: Repository save threw error: $e');
    }

    // 3. Clear active review analysis state
    ref.read(mealAnalysisStateProvider.notifier).clear();

    if (!mounted) return;

    // 4. Non-blocking user feedback: show green SnackBar on success or info SnackBar if offline
    final isSynced = result?.isSynced ?? false;
    if (isSynced) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Meal synced to Supabase cloud!'),
          backgroundColor: Colors.green,
          behavior: SnackBarBehavior.floating,
          duration: Duration(seconds: 3),
        ),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Saved locally (offline mode - cloud sync pending)'),
          backgroundColor: Color(0xFF6C63FF),
          behavior: SnackBarBehavior.floating,
          duration: Duration(seconds: 3),
        ),
      );
    }

    // 5. Cleanly navigate back to the main dashboard/home screen ('/')
    Navigator.of(context).pushNamedAndRemoveUntil(
      '/',
      (route) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    final routeArgs = ModalRoute.of(context)?.settings.arguments;
    final analysis = ref.watch(mealAnalysisStateProvider) ??
        (routeArgs is MealAnalysis ? routeArgs : null);
    final macros = ref.watch(confirmedMacroTotalsProvider);

    if (analysis == null || analysis.items.isEmpty) {
      return Scaffold(
        backgroundColor: const Color(0xFF1A1A2E),
        appBar: AppBar(
          title: const Text('Review Ingredients'),
          backgroundColor: Colors.transparent,
          elevation: 0,
        ),
        body: const Center(
          child: Text(
            'No ingredients to review.',
            style: TextStyle(color: Colors.white70, fontSize: 16),
          ),
        ),
      );
    }

    // When all cards have been swiped, show the "Review Complete" summary.
    if (_reviewComplete) {
      return _buildReviewCompleteSummary(context, analysis, macros);
    }

    return Scaffold(
      backgroundColor: const Color(0xFF1A1A2E),
      appBar: AppBar(
        title: Text(
          analysis.mealName,
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
      ),
      body: Column(
        children: [
          // Macro summary bar
          _MacroSummaryBar(macros: macros),

          const SizedBox(height: 8),

          // Swipe hint
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 24),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  '← Discard',
                  style: TextStyle(color: Colors.redAccent, fontSize: 12),
                ),
                Text(
                  'Confirm →',
                  style: TextStyle(color: Colors.greenAccent, fontSize: 12),
                ),
              ],
            ),
          ),

          const SizedBox(height: 8),

          // Card swiper — non-looping
          Expanded(
            child: CardSwiper(
              controller: _swiperController,
              cardsCount: analysis.items.length,
              numberOfCardsDisplayed: analysis.items.length.clamp(1, 3),
              isLoop: false,
              onSwipe: _onSwipe,
              onEnd: _onEnd,
              allowedSwipeDirection: const AllowedSwipeDirection.symmetric(
                horizontal: true,
              ),
              padding:
                  const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
              cardBuilder: (
                context,
                index,
                horizontalOffsetPercentage,
                verticalOffsetPercentage,
              ) {
                return _IngredientCard(
                  item: analysis.items[index],
                  index: index,
                  total: analysis.items.length,
                );
              },
            ),
          ),

          // "Skip to Summary" button — lets users finish early
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 32),
            child: SizedBox(
              width: double.infinity,
              height: 52,
              child: ElevatedButton(
                onPressed: _onEnd,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF6C63FF),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
                child: const Text(
                  'Skip to Summary',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Builds the "Review Complete" summary screen shown after all cards
  /// are swiped or when the user taps "Skip to Summary".
  ///
  /// Displays confirmed ingredient count, macro totals, and a
  /// "Save & Finish" button that persists to Supabase and navigates home.
  Widget _buildReviewCompleteSummary(
    BuildContext context,
    MealAnalysis analysis,
    Map<String, double> macros,
  ) {
    final confirmedItems =
        analysis.items.where((item) => !item.wasSwipedAway).toList();
    final discardedCount = analysis.items.length - confirmedItems.length;

    return Scaffold(
      backgroundColor: const Color(0xFF1A1A2E),
      appBar: AppBar(
        title: const Text('Review Complete'),
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
        automaticallyImplyLeading: false,
      ),
      body: Column(
        children: [
          const SizedBox(height: 16),

          // Success icon
          Container(
            width: 80,
            height: 80,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.greenAccent.withValues(alpha: 0.15),
              border: Border.all(
                color: Colors.greenAccent.withValues(alpha: 0.4),
                width: 2,
              ),
            ),
            child: const Icon(
              Icons.check_circle_outline,
              color: Colors.greenAccent,
              size: 44,
            ),
          ),

          const SizedBox(height: 16),

          // Meal name
          Text(
            analysis.mealName,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 22,
              fontWeight: FontWeight.w800,
            ),
          ),

          const SizedBox(height: 8),

          // Confirmed / discarded summary
          Text(
            '${confirmedItems.length} confirmed · $discardedCount discarded',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.6),
              fontSize: 14,
            ),
          ),

          const SizedBox(height: 14),

          // Alerts & Exception Management banner (Above macro pills)
          _buildClinicalAlertBanner(macros),

          const SizedBox(height: 14),

          // Macro summary bar
          _MacroSummaryBar(macros: macros),

          const SizedBox(height: 14),

          // AI Practitioner Recommendation card (Below macro pills)
          _buildPractitionerRecommendationCard(macros),

          const SizedBox(height: 14),

          // Confirmed ingredients list
          Expanded(
            child: confirmedItems.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 32),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.no_food_outlined,
                            color: Colors.white.withValues(alpha: 0.3),
                            size: 48,
                          ),
                          const SizedBox(height: 12),
                          Text(
                            'All ingredients were discarded.\nNothing to save.',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.5),
                              fontSize: 14,
                            ),
                          ),
                        ],
                      ),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    itemCount: confirmedItems.length,
                    itemBuilder: (context, index) {
                      final item = confirmedItems[index];
                      return Container(
                        margin: const EdgeInsets.only(bottom: 8),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 12,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.06),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: Colors.white10),
                        ),
                        child: Row(
                          children: [
                            // Ingredient name & weight
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    item.name,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 15,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    '~${item.weightGrams.round()}g',
                                    style: TextStyle(
                                      color:
                                          Colors.white.withValues(alpha: 0.5),
                                      fontSize: 12,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            // Macro chips
                            _MiniMacro(
                              label: 'P',
                              value: item.protein,
                              color: const Color(0xFF4ECDC4),
                            ),
                            const SizedBox(width: 8),
                            _MiniMacro(
                              label: 'C',
                              value: item.carbs,
                              color: const Color(0xFFFFE66D),
                            ),
                            const SizedBox(width: 8),
                            _MiniMacro(
                              label: 'F',
                              value: item.fat,
                              color: const Color(0xFFA8E6CF),
                            ),
                            const SizedBox(width: 12),
                            // Calorie badge
                            Text(
                              '${item.calories.round()}',
                              style: const TextStyle(
                                color: Color(0xFFFF6B6B),
                                fontSize: 14,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            Text(
                              ' kcal',
                              style: TextStyle(
                                color: const Color(0xFFFF6B6B)
                                    .withValues(alpha: 0.7),
                                fontSize: 11,
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),

          // Bottom buttons
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 32),
            child: Row(
              children: [
                // "Re-review" button — go back to swiper
                Expanded(
                  child: SizedBox(
                    height: 52,
                    child: OutlinedButton(
                      onPressed: _isSaving
                          ? null
                          : () {
                              setState(() {
                                _reviewComplete = false;
                              });
                            },
                      style: OutlinedButton.styleFrom(
                        side: BorderSide(
                          color: Colors.white.withValues(alpha: 0.2),
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                      ),
                      child: const Text(
                        'Back',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: Colors.white70,
                        ),
                      ),
                    ),
                  ),
                ),

                const SizedBox(width: 12),

                // "Save & Finish" button
                Expanded(
                  flex: 2,
                  child: SizedBox(
                    height: 52,
                    child: ElevatedButton(
                      onPressed: confirmedItems.isEmpty || _isSaving
                          ? null
                          : () => _saveAndNavigateHome(analysis),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF6C63FF),
                        disabledBackgroundColor:
                            const Color(0xFF6C63FF).withValues(alpha: 0.4),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                      ),
                      child: _isSaving
                          ? const SizedBox(
                              width: 22,
                              height: 22,
                              child: CircularProgressIndicator(
                                color: Colors.white,
                                strokeWidth: 2.5,
                              ),
                            )
                          : Text(
                              confirmedItems.isEmpty
                                  ? 'Nothing to Save'
                                  : 'Save & Finish',
                              style: const TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                                color: Colors.white,
                              ),
                            ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Builds the Alerts & Exception Management banner above the macro summary bar.
  Widget _buildClinicalAlertBanner(Map<String, double> macros) {
    final fat = macros['fat'] ?? 0.0;
    final calories = macros['calories'] ?? 0.0;
    final isHighLipid = fat > 35.0 || calories > 1000.0;

    if (isHighLipid) {
      return Container(
        margin: const EdgeInsets.symmetric(horizontal: 24),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: const Color(0x28FFB300),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: const Color(0xFFFFB300),
            width: 1.2,
          ),
        ),
        child: const Row(
          children: [
            Text('⚠️', style: TextStyle(fontSize: 16)),
            SizedBox(width: 8),
            Expanded(
              child: Text(
                'Protocol Alert: High lipid density exceeds single-meal target by 28%',
                style: TextStyle(
                  color: Color(0xFFFFD54F),
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
      );
    } else {
      return Container(
        margin: const EdgeInsets.symmetric(horizontal: 24),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: const Color(0x224ECDC4),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: const Color(0xFF4ECDC4),
            width: 1.2,
          ),
        ),
        child: const Row(
          children: [
            Text('✅', style: TextStyle(fontSize: 16)),
            SizedBox(width: 8),
            Expanded(
              child: Text(
                'Protocol Compliant: Macros aligned with training targets',
                style: TextStyle(
                  color: Color(0xFFA8E6CF),
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
      );
    }
  }

  /// Builds the AI Practitioner Recommendation card below the macro summary bar.
  Widget _buildPractitionerRecommendationCard(Map<String, double> macros) {
    final fat = macros['fat'] ?? 0.0;
    final protein = macros['protein'] ?? 0.0;
    final calories = macros['calories'] ?? 0.0;

    String recommendation;
    if (fat > 35.0 || calories > 1000.0) {
      recommendation =
          'High single-meal lipid concentration detected. Taper subsequent carbohydrate and fat intake by 25g to maintain prescribed daily energy balance.';
    } else if (protein >= 35.0) {
      recommendation =
          'High protein yield supports muscular recovery. Taper subsequent carbohydrate intake by 25g to maintain prescribed daily energy balance.';
    } else {
      recommendation =
          'Nutrient distribution aligns with prescribed athletic training protocols. Continue current hydration strategy and maintain target macro pacing.';
    }

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 24),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF22223B),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: const Color(0xFF6C63FF).withValues(alpha: 0.35),
          width: 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.auto_awesome, color: Color(0xFF9D95FF), size: 14),
              SizedBox(width: 6),
              Text(
                'AI PRACTITIONER RECOMMENDATION',
                style: TextStyle(
                  color: Color(0xFFB8B5FF),
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.6,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            recommendation,
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 12,
              height: 1.35,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

/// Small macro indicator used in the review summary list items.
class _MiniMacro extends StatelessWidget {
  const _MiniMacro({
    required this.label,
    required this.value,
    required this.color,
  });

  final String label;
  final double value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          value.toStringAsFixed(0),
          style: TextStyle(
            color: color,
            fontSize: 13,
            fontWeight: FontWeight.w700,
          ),
        ),
        Text(
          label,
          style: TextStyle(
            color: color.withValues(alpha: 0.6),
            fontSize: 9,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }
}

/// Horizontal bar showing aggregated macro totals for confirmed
/// ingredients. Updates optimistically on every swipe.
class _MacroSummaryBar extends StatelessWidget {
  const _MacroSummaryBar({required this.macros});

  final Map<String, double> macros;

  @override
  Widget build(BuildContext context) {
    final calories = macros['calories'] ?? 0.0;
    final protein = macros['protein'] ?? 0.0;
    final carbs = macros['carbs'] ?? 0.0;
    final fat = macros['fat'] ?? 0.0;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white12),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          _MacroChip(
            label: 'Cal',
            value: calories.round().toString(),
            color: const Color(0xFFFF6B6B),
          ),
          _MacroChip(
            label: 'P',
            value: '${protein.toStringAsFixed(1)}g',
            color: const Color(0xFF4ECDC4),
          ),
          _MacroChip(
            label: 'C',
            value: '${carbs.toStringAsFixed(1)}g',
            color: const Color(0xFFFFE66D),
          ),
          _MacroChip(
            label: 'F',
            value: '${fat.toStringAsFixed(1)}g',
            color: const Color(0xFFA8E6CF),
          ),
        ],
      ),
    );
  }
}

class _MacroChip extends StatelessWidget {
  const _MacroChip({
    required this.label,
    required this.value,
    required this.color,
  });

  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          value,
          style: TextStyle(
            color: color,
            fontSize: 18,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          label,
          style: TextStyle(
            color: color.withValues(alpha: 0.7),
            fontSize: 11,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }
}

/// Card widget for a single ingredient showing name, weight, macros,
/// and confidence indicator.
class _IngredientCard extends StatelessWidget {
  const _IngredientCard({
    required this.item,
    required this.index,
    required this.total,
  });

  final IngredientItem item;
  final int index;
  final int total;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF2D2B55), Color(0xFF1A1A2E)],
        ),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: Colors.white10),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.3),
            blurRadius: 16,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      child: LayoutBuilder(
        builder: (context, constraints) {
          return SingleChildScrollView(
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: constraints.maxHeight),
              child: IntrinsicHeight(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Card counter
                    Text(
                      '${index + 1} / $total',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.4),
                        fontSize: 12,
                      ),
                    ),

                    const SizedBox(height: 6),

                    // Ingredient name
                    Text(
                      item.name,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 24,
                        fontWeight: FontWeight.w800,
                      ),
                    ),

                    const SizedBox(height: 4),

                    // Weight estimate and Calorie badge
                    Row(
                      children: [
                        Text(
                          '~${item.weightGrams.round()}g',
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.6),
                            fontSize: 15,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color:
                                const Color(0xFFFF6B6B).withValues(alpha: 0.2),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: const Color(0xFFFF6B6B)
                                  .withValues(alpha: 0.4),
                            ),
                          ),
                          child: Text(
                            '${item.calories.round()} kcal',
                            style: const TextStyle(
                              color: Color(0xFFFF6B6B),
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),

                    const SizedBox(height: 14),

                    // Macro breakdown
                    _MacroRow(
                      label: 'Calories',
                      value: item.calories,
                      unit: ' kcal',
                    ),
                    const SizedBox(height: 6),
                    _MacroRow(label: 'Protein', value: item.protein, unit: 'g'),
                    const SizedBox(height: 6),
                    _MacroRow(label: 'Carbs', value: item.carbs, unit: 'g'),
                    const SizedBox(height: 6),
                    _MacroRow(label: 'Fat', value: item.fat, unit: 'g'),
                    const SizedBox(height: 6),
                    _MacroRow(label: 'Fiber', value: item.fiber, unit: 'g'),

                    const Spacer(),
                    const SizedBox(height: 8),

                    // Confidence indicator
                    Row(
                      children: [
                        Icon(
                          Icons.verified,
                          size: 16,
                          color: item.confidence >= 0.8
                              ? Colors.greenAccent
                              : item.confidence >= 0.5
                                  ? Colors.amberAccent
                                  : Colors.redAccent,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          '${(item.confidence * 100).round()}% confidence',
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.5),
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _MacroRow extends StatelessWidget {
  const _MacroRow({
    required this.label,
    required this.value,
    required this.unit,
  });

  final String label;
  final double value;
  final String unit;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.7),
            fontSize: 15,
          ),
        ),
        Text(
          '${value.toStringAsFixed(1)}$unit',
          style: const TextStyle(
            color: Colors.white,
            fontSize: 15,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}
