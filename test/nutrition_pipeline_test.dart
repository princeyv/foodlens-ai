import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:core_nutrition_app/core/network/gemini_vision_service.dart';
import 'package:core_nutrition_app/core/utils/image_compressor_isolate.dart';
import 'package:core_nutrition_app/features/nutrition/data/nutrition_repository.dart';
import 'package:core_nutrition_app/features/nutrition/domain/models/ingredient_item.dart';
import 'package:core_nutrition_app/features/nutrition/domain/models/meal_analysis.dart';
import 'package:core_nutrition_app/features/nutrition/presentation/ingredient_swiper_screen.dart';
import 'package:core_nutrition_app/features/nutrition/providers/nutrition_providers.dart';
import 'package:core_nutrition_app/screens/dashboard_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_generative_ai/google_generative_ai.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;

void main() {
  group('IngredientItem and MealAnalysis Model Tests', () {
    test('IngredientItem parses JSON and calculates calories accurately', () {
      final json = {
        'name': 'Grilled Chicken Breast',
        'weight_grams': 150,
        'protein': 46.5,
        'carbs': 0.0,
        'fat': 5.4,
        'fiber': 0.0,
        'confidence': 0.95,
      };

      final item = IngredientItem.fromJson(json);
      expect(item.name, 'Grilled Chicken Breast');
      expect(item.weightGrams, 150.0);
      expect(item.protein, 46.5);
      expect(item.carbs, 0.0);
      expect(item.fat, 5.4);
      expect(item.fiber, 0.0);
      expect(item.confidence, 0.95);
      expect(item.wasSwipedAway, false);

      // (4 * 46.5) + (4 * 0) + (9 * 5.4) = 186.0 + 48.6 = 234.6
      expect(item.calories, closeTo(234.6, 0.01));
    });

    test('MealAnalysis parses JSON list of ingredients and computes totals', () {
      final json = {
        'meal_name': 'Chicken and Quinoa Bowl',
        'items': [
          {
            'name': 'Grilled Chicken Breast',
            'weight_grams': 150,
            'protein': 46.5,
            'carbs': 0.0,
            'fat': 5.4,
            'fiber': 0.0,
            'confidence': 0.95,
          },
          {
            'name': 'Cooked Quinoa',
            'weight_grams': 100,
            'protein': 4.4,
            'carbs': 21.3,
            'fat': 1.9,
            'fiber': 2.8,
            'confidence': 0.90,
          },
          {
            'name': 'Avocado Slice',
            'weight_grams': 50,
            'protein': 1.0,
            'carbs': 4.3,
            'fat': 7.3,
            'fiber': 3.4,
            'confidence': 0.85,
          },
        ],
      };

      final analysis = MealAnalysis.fromJson(json);
      expect(analysis.mealName, 'Chicken and Quinoa Bowl');
      expect(analysis.items.length, 3);
      expect(analysis.items[0].name, 'Grilled Chicken Breast');
      expect(analysis.items[1].name, 'Cooked Quinoa');
      expect(analysis.items[2].name, 'Avocado Slice');
      expect(analysis.estimatedCalories, greaterThan(0));
    });

    test('MealAnalysis.createDemoMeal creates athletic demo meal with 4 clinical ingredients and 95% confidence', () {
      final demo = MealAnalysis.createDemoMeal();

      expect(demo.mealName, 'Grilled Salmon & Quinoa Bowl');
      expect(demo.items.length, 4);

      final salmon = demo.items[0];
      expect(salmon.name, 'Atlantic Salmon');
      expect(salmon.weightGrams, 200.0);
      expect(salmon.protein, 40.0);
      expect(salmon.fat, 26.0);
      expect(salmon.confidence, 0.95);

      final quinoa = demo.items[1];
      expect(quinoa.name, 'Quinoa');
      expect(quinoa.weightGrams, 150.0);
      expect(quinoa.confidence, 0.95);

      final broccoli = demo.items[2];
      expect(broccoli.name, 'Steamed Broccoli');
      expect(broccoli.weightGrams, 100.0);
      expect(broccoli.confidence, 0.95);

      final dressing = demo.items[3];
      expect(dressing.name, 'Olive Oil Dressing');
      expect(dressing.weightGrams, 15.0);
      expect(dressing.confidence, 0.95);

      expect(demo.estimatedCalories, closeTo(743.0, 1.0));
      expect(demo.overallHealthScore, 95.0);
    });
  });

  group('Riverpod State & Optimistic Swipe Recalculation', () {
    test('MealAnalysisNotifier and confirmedMacroTotalsProvider recalculate on swipe', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      const chicken = IngredientItem(
        name: 'Chicken Breast',
        weightGrams: 150,
        protein: 40.0,
        carbs: 0.0,
        fat: 5.0,
        fiber: 0.0,
        confidence: 0.95,
      );
      const rice = IngredientItem(
        name: 'Brown Rice',
        weightGrams: 100,
        protein: 3.0,
        carbs: 25.0,
        fat: 1.0,
        fiber: 2.0,
        confidence: 0.90,
      );

      const analysis = MealAnalysis(
        mealName: 'Chicken & Rice',
        items: [chicken, rice],
        estimatedCalories: 300,
        overallHealthScore: 9.0,
      );

      // Initially null
      expect(container.read(mealAnalysisStateProvider), isNull);
      expect(container.read(confirmedMacroTotalsProvider)['calories'], 0.0);

      // Set analysis
      container.read(mealAnalysisStateProvider.notifier).setAnalysis(analysis);
      expect(container.read(mealAnalysisStateProvider)?.items.length, 2);

      // Macro totals with both items:
      // Protein: 40 + 3 = 43g
      // Carbs: 0 + 25 = 25g
      // Fat: 5 + 1 = 6g
      // Fiber: 0 + 2 = 2g
      // Calories: 4*43 + 4*25 + 9*6 = 172 + 100 + 54 = 326
      var macros = container.read(confirmedMacroTotalsProvider);
      expect(macros['protein'], 43.0);
      expect(macros['carbs'], 25.0);
      expect(macros['fat'], 6.0);
      expect(macros['fiber'], 2.0);
      expect(macros['calories'], closeTo(326.0, 0.01));

      // Discard rice (index 1) - swipe left
      container.read(mealAnalysisStateProvider.notifier).markSwipedAway(1);

      macros = container.read(confirmedMacroTotalsProvider);
      expect(macros['protein'], 40.0);
      expect(macros['carbs'], 0.0);
      expect(macros['fat'], 5.0);
      // Calories for only chicken: 4*40 + 4*0 + 9*5 = 160 + 45 = 205
      expect(macros['calories'], closeTo(205.0, 0.01));

      // Confirm rice back (index 1) - swipe right
      container.read(mealAnalysisStateProvider.notifier).confirmIngredient(1);
      macros = container.read(confirmedMacroTotalsProvider);
      expect(macros['protein'], 43.0);
      expect(macros['calories'], closeTo(326.0, 0.01));
    });
  });

  group('IngredientSwiperScreen Widget Tests', () {
    testWidgets('Displays "No ingredients to review." when analysis is null',
        (tester) async {
      await tester.pumpWidget(
        const ProviderScope(
          child: MaterialApp(
            home: IngredientSwiperScreen(),
          ),
        ),
      );

      expect(find.text('No ingredients to review.'), findsOneWidget);
      expect(find.text('Review Ingredients'), findsOneWidget);
    });

    testWidgets('Renders card deck and macros when mealAnalysisStateProvider is populated',
        (tester) async {
      const analysis = MealAnalysis(
        mealName: 'Steak & Salad Bowl',
        items: [
          IngredientItem(
            name: 'Ribeye Steak',
            weightGrams: 200,
            protein: 48.0,
            carbs: 0.0,
            fat: 32.0,
            fiber: 0.0,
            confidence: 0.96,
          ),
          IngredientItem(
            name: 'Mixed Greens',
            weightGrams: 80,
            protein: 1.5,
            carbs: 3.0,
            fat: 0.2,
            fiber: 2.1,
            confidence: 0.88,
          ),
        ],
        estimatedCalories: 480,
        overallHealthScore: 8.5,
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            mealAnalysisStateProvider.overrideWith((ref) {
              final notifier = MealAnalysisNotifier();
              notifier.setAnalysis(analysis);
              return notifier;
            }),
          ],
          child: const MaterialApp(
            home: IngredientSwiperScreen(),
          ),
        ),
      );

      await tester.pumpAndSettle();

      // Meal name in AppBar
      expect(find.text('Steak & Salad Bowl'), findsOneWidget);

      // Macro summary bar elements
      expect(find.text('Cal'), findsOneWidget);
      expect(find.text('P'), findsOneWidget);
      expect(find.text('C'), findsOneWidget);
      expect(find.text('F'), findsOneWidget);

      // Swipe hints
      expect(find.text('← Discard'), findsOneWidget);
      expect(find.text('Confirm →'), findsOneWidget);

      // First ingredient card
      expect(find.text('Ribeye Steak'), findsOneWidget);
      expect(find.text('~200g'), findsOneWidget);
      expect(find.text('Protein'), findsWidgets);
      expect(find.text('48.0g'), findsOneWidget);

      // Skip to Summary button
      expect(find.text('Skip to Summary'), findsOneWidget);
    });

    testWidgets('Synchronizes state when MealAnalysis is passed via route arguments',
        (tester) async {
      const analysis = MealAnalysis(
        mealName: 'Salmon Bowl',
        items: [
          IngredientItem(
            name: 'Atlantic Salmon',
            weightGrams: 180,
            protein: 36.0,
            carbs: 0.0,
            fat: 22.0,
            fiber: 0.0,
            confidence: 0.94,
          ),
        ],
        estimatedCalories: 340,
        overallHealthScore: 9.2,
      );

      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            initialRoute: '/',
            routes: {
              '/': (context) => Scaffold(
                    body: Center(
                      child: ElevatedButton(
                        onPressed: () {
                          Navigator.pushNamed(
                            context,
                            '/nutrition/swiper',
                            arguments: analysis,
                          );
                        },
                        child: const Text('Go'),
                      ),
                    ),
                  ),
              '/nutrition/swiper': (context) => const IngredientSwiperScreen(),
            },
          ),
        ),
      );

      await tester.tap(find.text('Go'));
      await tester.pumpAndSettle();

      expect(find.text('Salmon Bowl'), findsOneWidget);
      expect(find.text('Atlantic Salmon'), findsOneWidget);
      expect(find.text('~180g'), findsOneWidget);
      expect(find.text('36.0g'), findsWidgets);
    });
  });

  group('Clinical Nutrition Decision-Support System Tests', () {
    testWidgets('DashboardScreen renders Athlete ID, daily adherence targets, and recent feed', (tester) async {
      await tester.pumpWidget(
        const ProviderScope(
          child: MaterialApp(
            home: DashboardScreen(),
          ),
        ),
      );

      await tester.pumpAndSettle();

      // Header verification
      expect(find.text('FoodLens Clinical'), findsOneWidget);
      expect(find.textContaining('Athlete ID #8492'), findsOneWidget);

      // 4 Target adherence metrics
      expect(find.text('DAILY TARGET ADHERENCE'), findsOneWidget);
      expect(find.text('Calories'), findsOneWidget);
      expect(find.text('Protein'), findsOneWidget);
      expect(find.text('Carbohydrates'), findsOneWidget);
      expect(find.text('Lipids (Fat)'), findsOneWidget);

      // Floating action button
      expect(find.text('Scan Meal'), findsOneWidget);

      // Open Practitioner Audit Report modal
      await tester.tap(find.text('Summary Report'));
      await tester.pumpAndSettle();

      // Modal contents verification
      expect(find.textContaining('Practitioner Audit Report'), findsOneWidget);
      expect(find.textContaining('Weekly Protocol Adherence'), findsOneWidget);
      expect(find.text('91%'), findsOneWidget);
      expect(find.textContaining('HUMAN-IN-THE-LOOP'), findsOneWidget);
      expect(find.text('AI CLINICAL ACTION PLAN (DIETITIAN GUIDANCE)'), findsOneWidget);
    });

    testWidgets('Multi-Athlete Roster Switcher and Clinical SOAP Note EHR Generator', (tester) async {
      await tester.pumpWidget(
        const ProviderScope(
          child: MaterialApp(
            home: DashboardScreen(),
          ),
        ),
      );

      await tester.pumpAndSettle();

      // Verify default profile targets (Marcus Vance: 2,400 kcal)
      expect(find.textContaining('2400 kcal'), findsOneWidget);

      // Tap roster switcher to open roster modal
      await tester.tap(find.textContaining('Athlete ID #8492'));
      await tester.pumpAndSettle();

      // Verify roster profiles
      expect(find.text('Clinical Athlete Roster'), findsOneWidget);
      expect(find.textContaining('Elena Rostova (#1042)'), findsOneWidget);
      expect(find.textContaining('Jordan Reed (#3109)'), findsOneWidget);

      // Select Elena Rostova (Bariatric - 1,400 kcal)
      await tester.tap(find.textContaining('Elena Rostova (#1042)'));
      await tester.pumpAndSettle();

      // Adherence target bars now reflect Elena's limits (1,400 kcal, 110g P, 80g C, 45g F)
      expect(find.textContaining('1400 kcal'), findsOneWidget);
      expect(find.textContaining('110 g'), findsOneWidget);
      expect(find.textContaining('80 g'), findsOneWidget);
      expect(find.textContaining('45 g'), findsOneWidget);

      // Open Summary Report (SOAP Note Generator)
      await tester.tap(find.text('Summary Report'));
      await tester.pumpAndSettle();

      // Verify EHR Header Details
      expect(find.textContaining('UNT Athletic Performance & Clinical Nutrition Lab'), findsOneWidget);
      expect(find.textContaining('Dr. K. Vance, RD, CSSD'), findsOneWidget);
      expect(find.textContaining('Elena Rostova'), findsWidgets);

      // Verify SOAP sections
      expect(find.textContaining('[S] SUBJECTIVE'), findsOneWidget);
      expect(find.textContaining('[O] OBJECTIVE DATA'), findsOneWidget);
      expect(find.textContaining('[A] CLINICAL ASSESSMENT'), findsOneWidget);
      expect(find.textContaining('[P] '), findsOneWidget);

      // Verify Copy Formal EHR Record button and tap it
      final copyBtn = find.text('Copy Formal EHR Record to Clipboard');
      expect(copyBtn, findsOneWidget);
      await tester.ensureVisible(copyBtn);
      await tester.tap(copyBtn);
      await tester.pumpAndSettle();

      // Verify SnackBar confirmation
      expect(find.text('Formal EHR SOAP Note copied to clipboard!'), findsOneWidget);
    });
  });

  group('Gemini Response Parsing & Markdown Stripping Tests', () {
    test('Correctly extracts and parses meal JSON wrapped in markdown fences', () {
      const rawGeminiOutput = '''
```json
{
  "meal_name": "Avocado Toast with Egg",
  "items": [
    {
      "name": "Sourdough Bread",
      "weight_grams": 70,
      "protein": 6.0,
      "carbs": 34.0,
      "fat": 1.5,
      "fiber": 2.0,
      "confidence": 0.98
    },
    {
      "name": "Poached Egg",
      "weight_grams": 50,
      "protein": 6.3,
      "carbs": 0.4,
      "fat": 4.8,
      "fiber": 0.0,
      "confidence": 0.95
    }
  ]
}
```
''';

      // Test markdown stripper logic matching GeminiVisionService
      String cleaned = rawGeminiOutput.trim();
      if (cleaned.startsWith('```json')) {
        cleaned = cleaned.substring(7);
      } else if (cleaned.startsWith('```')) {
        cleaned = cleaned.substring(3);
      }
      if (cleaned.endsWith('```')) {
        cleaned = cleaned.substring(0, cleaned.length - 3);
      }
      cleaned = cleaned.trim();

      final parsed = jsonDecode(cleaned) as Map<String, dynamic>;
      final analysis = MealAnalysis.fromJson(parsed);

      expect(analysis.mealName, 'Avocado Toast with Egg');
      expect(analysis.items.length, 2);
      expect(analysis.items[0].name, 'Sourdough Bread');
      expect(analysis.items[0].protein, 6.0);
      expect(analysis.items[0].carbs, 34.0);
      expect(analysis.items[0].fat, 1.5);
      expect(analysis.items[0].calories, closeTo(173.5, 0.01));

      expect(analysis.items[1].name, 'Poached Egg');
      expect(analysis.items[1].protein, 6.3);
      expect(analysis.items[1].carbs, 0.4);
      expect(analysis.items[1].fat, 4.8);
      expect(analysis.items[1].calories, closeTo(70.0, 0.01));
    });

    test('NutritionRepository handles repository-level analyzeMealPhotos dispatch', () async {
      const fakeAnalysis = MealAnalysis(
        mealName: 'Greek Yogurt Parfait',
        items: [
          IngredientItem(
            name: 'Greek Yogurt',
            weightGrams: 170,
            protein: 17.0,
            carbs: 6.0,
            fat: 0.0,
            fiber: 0.0,
            confidence: 0.97,
          ),
        ],
        estimatedCalories: 92,
        overallHealthScore: 9.5,
      );

      final repo = FakeNutritionRepository(fakeAnalysis);
      final result = await repo.analyzeMealPhotos(['/path/photo1.jpg', '/path/photo2.jpg', '/path/photo3.jpg']);

      expect(result.mealName, 'Greek Yogurt Parfait');
      expect(result.items.length, 1);
      expect(repo.lastPassedPaths?.length, 3);
    });

    group('GeminiVisionService Fast Failover and Latency Optimization', () {
      test('Correctly identifies timeout vs fallbackable errors (503, 429, overloaded, etc.)', () {
        final service = GeminiVisionService.instance;

        // Default timeout is 30 seconds
        expect(service.modelTimeout, const Duration(seconds: 30));

        // Timeout identification (non-fallbackable to prevent broken multi-retry wait cascades)
        expect(service.isTimeoutError(TimeoutException('Request timed out')), isTrue);
        expect(service.isTimeoutError(Exception('Network request timed out')), isTrue);
        expect(service.isFallbackableError(TimeoutException('Request timed out')), isFalse);

        // Transient retryable errors (503, 429, overloaded, etc.)
        expect(service.isTransientError(Exception('503 Service Unavailable')), isTrue);
        expect(service.isTransientError(Exception('HTTP 429: Too Many Requests')), isTrue);
        expect(service.isTransientError(Exception('RESOURCE_EXHAUSTED')), isTrue);
        expect(service.isTransientError(Exception('The model is overloaded. Please try again later.')), isTrue);
        expect(service.isTransientError(Exception('Rate limit exceeded')), isTrue);
        expect(service.isTransientError(Exception('High demand on AI service')), isTrue);
        expect(service.isTransientError(Exception('SocketException: Connection failed')), isTrue);

        // Non-transient errors (400, 404, invalid key, etc.)
        expect(service.isTransientError(Exception('400 Bad Request')), isFalse);
        expect(service.isTransientError(Exception('404 Not Found')), isFalse);
        expect(service.isTransientError(Exception('Invalid API Key')), isFalse);
        expect(service.isTransientError(Exception('Malformed prompt syntax')), isFalse);
      });

      test('GeminiVisionService activeModel is gemini-2.5-flash with default fallback models', () {
        expect(GeminiVisionService.activeModel, 'gemini-2.5-flash');
        expect(GeminiVisionService.defaultFallbackModels, [
          'gemini-2.5-flash',
          'gemini-3-flash-preview',
          'gemini-3.0-flash',
          'gemini-2.5-pro',
          'gemini-flash-latest',
        ]);
      });

      test('Fallback loop: falls back from gemini-2.5-flash to gemini-flash-latest on 503 and succeeds', () async {
        final service = GeminiVisionService.instance;
        service.fallbackModels = List.from(GeminiVisionService.defaultFallbackModels);
        final attemptedModels = <String>[];

        service.mockGenerateContentWithModel = (modelName, content) async {
          attemptedModels.add(modelName);
          if (modelName == 'gemini-2.5-flash') {
            throw Exception('503 Service Unavailable (High Demand)');
          }
          return GenerateContentResponse(
            [
              Candidate(
                Content.text('{"meal_name": "Oatmeal with Blueberries", "items": []}'),
                null,
                null,
                null,
                null,
              )
            ],
            null,
          );
        };

        final response = await service.generateContentWithRetry(
          content: [Content.text('test')],
        );

        expect(attemptedModels, ['gemini-2.5-flash', 'gemini-flash-latest']);
        expect(response.text, contains('Oatmeal with Blueberries'));
        service.mockGenerateContentWithModel = null;
      });

      test('Auto-discovery: dynamically queries server and executes discovered model when primary models return 404', () async {
        final service = GeminiVisionService.instance;
        service.fallbackModels = List.from(GeminiVisionService.defaultFallbackModels);
        final attemptedModels = <String>[];

        // Mock auto-discovery returning 'gemini-2.0-flash'
        service.mockDiscoverModel = (apiKey) async => 'gemini-2.0-flash';

        service.mockGenerateContentWithModel = (modelName, content) async {
          attemptedModels.add(modelName);
          if (modelName == 'gemini-2.5-flash' || modelName == 'gemini-flash-latest') {
            throw Exception('HTTP 404: Model Not Found');
          }
          return GenerateContentResponse(
            [
              Candidate(
                Content.text('{"meal_name": "Discovered Model Salad", "items": []}'),
                null,
                null,
                null,
                null,
              )
            ],
            null,
          );
        };

        final response = await service.generateContentWithRetry(
          content: [Content.text('test')],
        );

        expect(attemptedModels, [
          'gemini-2.5-flash',
          'gemini-flash-latest',
          'gemini-2.0-flash',
        ]);
        expect(response.text, contains('Discovered Model Salad'));
        service.mockGenerateContentWithModel = null;
        service.mockDiscoverModel = null;
      });

      test('Fallback loop: when all models fail, includes primary model error in exception message', () async {
        final service = GeminiVisionService.instance;
        service.fallbackModels = ['gemini-2.5-flash', 'gemini-flash-latest'];
        final attemptedModels = <String>[];

        service.mockGenerateContentWithModel = (modelName, content) async {
          attemptedModels.add(modelName);
          if (modelName == 'gemini-2.5-flash') {
            throw Exception('HTTP 404: Primary Model Deprecated');
          }
          throw Exception('HTTP 503: Fallback Model Overloaded');
        };

        try {
          await service.generateContentWithRetry(
            content: [Content.text('test')],
          );
          fail('Should have thrown GeminiAnalysisException');
        } on GeminiAnalysisException catch (e) {
          // Verify both primary error and fallback error are preserved
          expect(e.message, contains('Fallback Model Overloaded'));
          expect(e.message, contains('Primary model error'));
          expect(e.message, contains('Primary Model Deprecated'));
          expect(attemptedModels, ['gemini-2.5-flash', 'gemini-flash-latest']);
        } finally {
          service.mockGenerateContentWithModel = null;
          service.fallbackModels = List.from(GeminiVisionService.defaultFallbackModels);
        }
      });

      test('Timeout aborts retry loop immediately and returns polished user-friendly message', () async {
        final service = GeminiVisionService.instance;
        int attempts = 0;

        // Set a fast test timeout
        service.modelTimeout = const Duration(milliseconds: 50);

        service.mockGenerateContentWithModel = (modelName, content) async {
          attempts++;
          expect(modelName, 'gemini-2.5-flash');
          // Exceed the 50ms timeout
          await Future.delayed(const Duration(milliseconds: 150));
          return GenerateContentResponse(
            [
              Candidate(
                Content.text('{"meal_name": "Fast Failover Omelette", "items": []}'),
                null,
                null,
                null,
                null,
              )
            ],
            null,
          );
        };

        try {
          await service.generateContentWithRetry(
            content: [Content.text('test')],
          );
          fail('Should have thrown GeminiAnalysisException on timeout');
        } on GeminiAnalysisException catch (e) {
          expect(
            e.message,
            'Network request timed out. Please check your connection and try again.',
          );
          expect(attempts, 1);
        } finally {
          service.mockGenerateContentWithModel = null;
          service.modelTimeout = const Duration(seconds: 30);
        }
      });

      test('Graceful handling of non-food images returns MealAnalysis with No Food Detected without throwing', () async {
        final service = GeminiVisionService.instance;

        service.mockGenerateContentWithModel = (modelName, content) async {
          return GenerateContentResponse(
            [
              Candidate(
                Content.text('{"meal_name": "No Food Detected", "items": []}'),
                null,
                null,
                null,
                null,
              )
            ],
            null,
          );
        };

        final tempDir = Directory.systemTemp.createTempSync('non_food_test');
        final rawFile = File('${tempDir.path}/chair.jpg');
        final testImage = img.Image(width: 400, height: 400);
        img.fill(testImage, color: img.ColorRgb8(50, 50, 50));
        rawFile.writeAsBytesSync(img.encodeJpg(testImage));

        final result = await service.analyzeMealPhotos([rawFile.path]);

        expect(result.mealName, 'No Food Detected');
        expect(result.items, isEmpty);
        expect(result.estimatedCalories, 0.0);

        service.mockGenerateContentWithModel = null;
        tempDir.deleteSync(recursive: true);
      });

      test('FastGeminiHttpClient passes requests through without mutating body', () async {
        final service = GeminiVisionService.instance;

        String? interceptedBody;
        final mockInnerClient = MockHttpClient((request) async {
          if (request is http.Request) {
            interceptedBody = request.body;
          }
          return http.Response('{"candidates": []}', 200);
        });

        final fastClient = FastGeminiHttpClient(inner: mockInnerClient, service: service);
        final initialBody = jsonEncode({
          'contents': [
            {
              'role': 'user',
              'parts': [{'text': 'analyze food'}]
            }
          ],
          'generationConfig': {
            'temperature': 0.1,
            'responseMimeType': 'application/json',
          }
        });

        final postReq = http.Request(
          'POST',
          Uri.parse('https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent'),
        )..body = initialBody;

        await fastClient.send(postReq);

        expect(interceptedBody, equals(initialBody));
      });

      test('Does not fallback on fatal non-transient error (e.g. 400 Bad Request) and sanitizes error JSON', () async {
        final service = GeminiVisionService.instance;
        final attemptedModels = <String>[];

        const rawJsonError = 'GenerativeAIException: [GoogleGenerativeAI Error]: {"error": {"code": 400, "message": "API key not valid. Please pass a valid API key.", "status": "INVALID_ARGUMENT"}}';

        service.mockGenerateContentWithModel = (modelName, content) async {
          attemptedModels.add(modelName);
          throw Exception(rawJsonError);
        };

        try {
          await service.generateContentWithFallback(
            content: [Content.text('test')],
          );
          fail('Should have thrown GeminiAnalysisException');
        } on GeminiAnalysisException catch (e) {
          // Should only attempt the first model and stop immediately
          expect(attemptedModels, ['gemini-2.5-flash']);
          expect(e.message, contains('API key not valid'));
          expect(e.message, isNot(contains('{"error":')));
        } finally {
          service.mockGenerateContentWithModel = null;
        }
      });

      test('Pre-upload image compression resizes image to max 800px maintaining aspect ratio and quality 70%', () async {
        final tempDir = Directory.systemTemp.createTempSync('compress_test');
        final rawFile = File('${tempDir.path}/raw_large.jpg');

        // Create a 1600x1200 test image
        final testImage = img.Image(width: 1600, height: 1200);
        img.fill(testImage, color: img.ColorRgb8(100, 150, 200));
        rawFile.writeAsBytesSync(img.encodeJpg(testImage));

        final result = await ImageCompressorIsolate.compress(
          inputPath: rawFile.path,
          maxDimension: 800,
          quality: 70,
        );

        final compressedFile = File(result.path);
        expect(compressedFile.existsSync(), isTrue);

        final decoded = img.decodeImage(compressedFile.readAsBytesSync());
        expect(decoded, isNotNull);
        expect(decoded!.width, 800);
        expect(decoded.height, 600); // 1600:1200 aspect ratio preserved
        expect(result.sizeBytes, lessThan(300 * 1024)); // well within 300KB

        tempDir.deleteSync(recursive: true);
      });
    });

    group('Offline-First Resilient Meal Saving & Daily Macro Totals Tests', () {
      test('NutritionRepository saves meal to local cache and returns isSynced: false on network/offline failure', () async {
        final repo = NutritionRepository();

        const testMeal = MealAnalysis(
          mealName: 'Avocado Toast',
          items: [
            IngredientItem(
              name: 'Sourdough',
              weightGrams: 50,
              protein: 4.0,
              carbs: 25.0,
              fat: 1.0,
              fiber: 2.0,
              confidence: 0.9,
            ),
          ],
          estimatedCalories: 125,
          overallHealthScore: 8.5,
        );

        // Supabase is uninitialized/offline here; saveMealLog must catch error gracefully
        final result = await repo.saveMealLog(testMeal);

        expect(result.isSynced, isFalse);
        expect(repo.localMealLogs.length, 1);
        expect(repo.localMealLogs.first.mealName, 'Avocado Toast');
        expect(repo.pendingQueue.length, 1);
        expect(repo.pendingQueue.first.analysis.mealName, 'Avocado Toast');
      });

      test('NutritionRepository maps payload strictly to meals schema and meal_items', () async {
        final repo = NutritionRepository();
        final insertedMeals = <Map<String, dynamic>>[];
        final insertedMealItems = <dynamic>[];

        repo.mockInsertHandler = (table, data) async {
          if (table == 'meals') {
            insertedMeals.add(Map<String, dynamic>.from(data as Map));
          } else if (table == 'meal_items') {
            insertedMealItems.addAll(data as List);
          }
        };

        const meal = MealAnalysis(
          mealName: 'Salmon & Broccoli Dinner',
          items: [
            IngredientItem(
              name: 'Grilled Salmon',
              weightGrams: 200,
              protein: 40.0,
              carbs: 0.0,
              fat: 20.0,
              fiber: 0.0,
              confidence: 0.98,
            ),
            IngredientItem(
              name: 'Steamed Broccoli',
              weightGrams: 100,
              protein: 3.0,
              carbs: 7.0,
              fat: 0.5,
              fiber: 3.0,
              confidence: 0.95,
            ),
            IngredientItem(
              name: 'Discarded Dressing',
              weightGrams: 30,
              protein: 0.0,
              carbs: 5.0,
              fat: 10.0,
              fiber: 0.0,
              confidence: 0.90,
              wasSwipedAway: true,
            ),
          ],
          estimatedCalories: 350,
          overallHealthScore: 9.3,
        );

        final result = await repo.saveMealLog(meal);

        expect(result.isSynced, isTrue);
        expect(insertedMeals.length, 1);
        final row = insertedMeals.first;

        // Verify meals schema columns
        expect(row['id'], isNotEmpty);
        expect(row['id'], matches(RegExp(r'^[0-9a-fA-F-]{36}$'))); // UUID format
        expect(row['user_id'], '00000000-0000-0000-0000-000000000000');
        expect(row['logged_at'], isNotEmpty);
        expect(row['meal_type'], 'Salmon & Broccoli Dinner');
        expect(row['health_score'], closeTo(94.33, 0.1));
        expect(row['ai_raw_response'], contains('Salmon & Broccoli Dinner'));

        // Verify meal_items columns and foreign key linking
        expect(insertedMealItems.length, 3); // 3 items (both confirmed and discarded)
        final firstItem = insertedMealItems[0] as Map<String, dynamic>;
        expect(firstItem['meal_id'], row['id']);
        expect(firstItem['weight_grams'], 200.0);
        expect(firstItem['was_swiped_away'], false);
        expect(firstItem['user_override_grams'], isNull);
        expect(firstItem['food_id'], isNull);

        final thirdItem = insertedMealItems[2] as Map<String, dynamic>;
        expect(thirdItem['meal_id'], row['id']);
        expect(thirdItem['weight_grams'], 30.0);
        expect(thirdItem['was_swiped_away'], true);
        expect(thirdItem['user_override_grams'], isNull);
        expect(thirdItem['food_id'], isNull);
      });

      test('flushPendingMealQueue flushes pending meals to meals table on reconnection', () async {
        final repo = NutritionRepository();

        const pendingMeal1 = MealAnalysis(
          mealName: 'Pending Breakfast',
          items: [
            IngredientItem(
              name: 'Boiled Egg',
              weightGrams: 50,
              protein: 6.0,
              carbs: 0.5,
              fat: 5.0,
              fiber: 0.0,
              confidence: 0.99,
            ),
          ],
          estimatedCalories: 70,
          overallHealthScore: 9.0,
        );

        // Save while offline (no mock handler, Supabase uninitialized)
        await repo.saveMealLog(pendingMeal1);
        expect(repo.pendingQueue.length, 1);

        // Connection restored: attach mock handler and flush
        final syncedRows = <Map<String, dynamic>>[];
        repo.mockInsertHandler = (table, data) async {
          if (table == 'meals') {
            syncedRows.add(Map<String, dynamic>.from(data as Map));
          }
        };

        final syncedCount = await repo.flushPendingMealQueue();

        expect(syncedCount, 1);
        expect(repo.pendingQueue, isEmpty);
        expect(syncedRows.length, 1);
        expect(syncedRows.first['meal_type'], 'Pending Breakfast');
      });

      test('loggedMealsProvider and dailyMacroTotalsProvider update daily counters immediately', () {
        final container = ProviderContainer();
        addTearDown(container.dispose);

        // Initially zero
        expect(container.read(loggedMealsProvider), isEmpty);
        expect(container.read(dailyMacroTotalsProvider)['calories'], 0.0);

        const meal1 = MealAnalysis(
          mealName: 'Breakfast',
          items: [
            IngredientItem(
              name: 'Eggs',
              weightGrams: 100,
              protein: 13.0,
              carbs: 1.0,
              fat: 10.0,
              fiber: 0.0,
              confidence: 0.99,
            ),
          ],
          estimatedCalories: 146,
          overallHealthScore: 9.0,
        );

        container.read(loggedMealsProvider.notifier).addMeal(meal1);

        expect(container.read(loggedMealsProvider).length, 1);
        final macros1 = container.read(dailyMacroTotalsProvider);
        expect(macros1['protein'], 13.0);
        expect(macros1['carbs'], 1.0);
        expect(macros1['fat'], 10.0);
        // (4*13) + (4*1) + (9*10) = 52 + 4 + 90 = 146
        expect(macros1['calories'], 146.0);

        const meal2 = MealAnalysis(
          mealName: 'Lunch',
          items: [
            IngredientItem(
              name: 'Chicken Breast',
              weightGrams: 150,
              protein: 30.0,
              carbs: 0.0,
              fat: 3.0,
              fiber: 0.0,
              confidence: 0.95,
            ),
          ],
          estimatedCalories: 147,
          overallHealthScore: 9.5,
        );

        container.read(loggedMealsProvider.notifier).addMeal(meal2);

        expect(container.read(loggedMealsProvider).length, 2);
        final macros2 = container.read(dailyMacroTotalsProvider);
        expect(macros2['protein'], 43.0);
        expect(macros2['carbs'], 1.0);
        expect(macros2['fat'], 13.0);
        // (4*43) + (4*1) + (9*13) = 172 + 4 + 117 = 293
        expect(macros2['calories'], 293.0);
      });
    });
  });
}

class FakeNutritionRepository extends NutritionRepository {
  FakeNutritionRepository(this.mockAnalysis);

  final MealAnalysis mockAnalysis;
  List<String>? lastPassedPaths;

  @override
  Future<MealAnalysis> analyzeMealPhotos(List<String> photoPaths) async {
    lastPassedPaths = photoPaths;
    return mockAnalysis;
  }
}

class MockHttpClient extends http.BaseClient {
  MockHttpClient(this.handler);
  final Future<http.Response> Function(http.BaseRequest request) handler;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final response = await handler(request);
    return http.StreamedResponse(
      Stream.value(response.bodyBytes),
      response.statusCode,
      headers: response.headers,
    );
  }
}
