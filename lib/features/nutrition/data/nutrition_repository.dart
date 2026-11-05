import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../../../core/network/gemini_vision_service.dart';
import '../../../core/network/supabase_client.dart';
import '../domain/models/meal_analysis.dart';

/// Represents an item in the offline pending sync queue.
class PendingMealEntry {
  PendingMealEntry({
    required this.analysis,
    String? id,
    DateTime? queuedAt,
  })  : id = id ?? const Uuid().v4(),
        queuedAt = queuedAt ?? DateTime.now().toUtc();

  final String id;
  final MealAnalysis analysis;
  final DateTime queuedAt;
}

/// Result of saving a meal log.
class SaveMealResult {
  const SaveMealResult({
    required this.isSynced,
    this.mealId,
    this.errorMessage,
  });

  /// Whether the meal was successfully written to the remote Supabase database.
  final bool isSynced;

  /// The remote database record ID, if synced.
  final String? mealId;

  /// Error message if remote sync failed (offline / paused project).
  final String? errorMessage;
}

/// Repository for meal analysis and persisting nutrition data to Supabase.
///
/// Handles vision-based meal analysis via [GeminiVisionService] and CRUD
/// operations for the `meals` and `meal_items` tables with offline-first resiliency.
class NutritionRepository {
  NutritionRepository({
    this.visionService,
    this.customClient,
    String? fallbackUserId,
  }) : fallbackUserId = fallbackUserId ?? '00000000-0000-0000-0000-000000000000' {
    initializeConnectionListener();
  }

  static final instance = NutritionRepository();

  final GeminiVisionService? visionService;

  @visibleForTesting
  SupabaseClient? customClient;

  /// Fallback anonymous user UUID if no user is currently authenticated.
  @visibleForTesting
  String fallbackUserId;

  GeminiVisionService get _vision =>
      visionService ?? GeminiVisionService.instance;

  /// In-memory cache of saved meals for offline-first resilience.
  final List<MealAnalysis> _localMealLogs = [];

  /// Queue of pending meal entries waiting to be synced to Supabase `meals`.
  final List<PendingMealEntry> _pendingQueue = [];

  StreamSubscription<AuthState>? _authSubscription;

  /// Testing hook for intercepting table inserts.
  @visibleForTesting
  Future<void> Function(String table, dynamic data)? mockInsertHandler;

  /// Returns unmodifiable list of all locally saved meal logs.
  List<MealAnalysis> get localMealLogs => List.unmodifiable(_localMealLogs);

  /// Returns unmodifiable list of pending meals waiting for sync.
  List<PendingMealEntry> get pendingQueue => List.unmodifiable(_pendingQueue);

  /// Initialize listener for Supabase auth / connection events to trigger
  /// an immediate queue flush.
  void initializeConnectionListener() {
    try {
      final client = customClient ?? SupabaseClientProvider.client;
      _authSubscription?.cancel();
      _authSubscription = client.auth.onAuthStateChange.listen((data) {
        debugPrint(
          'NutritionRepository: Connection/Auth event (${data.event}). Flushing pending meals...',
        );
        flushPendingMealQueue();
      });
    } catch (_) {
      // Supabase may not be initialized yet in testing or early boot
    }
  }

  /// Analyze captured meal photos using Gemini Vision.
  Future<MealAnalysis> analyzeMealPhotos(List<String> photoPaths) async {
    return _vision.analyzeMealPhotos(photoPaths);
  }

  /// Save a confirmed [MealAnalysis] with offline-first resiliency.
  ///
  /// Persists the meal into local memory/cache immediately, queues it,
  /// and attempts to insert into Supabase `meals` and `meal_items`.
  ///
  /// If Supabase is offline or fails with [SocketException], [PostgrestException],
  /// or network errors, it catches the error, logs a warning, keeps the entry in
  /// [_pendingQueue], and returns a [SaveMealResult] with `isSynced: false`.
  Future<SaveMealResult> saveMealLog(
    MealAnalysis analysis, [
    BuildContext? context,
  ]) async {
    // 1. Always persist to local in-memory store immediately
    _localMealLogs.add(analysis);

    // 2. Add to pending queue
    final entry = PendingMealEntry(analysis: analysis);
    _pendingQueue.add(entry);

    // 3. Attempt immediate sync to Supabase `meals`
    final result = await _syncEntry(entry);
    if (result.isSynced) {
      _pendingQueue.remove(entry);
      // Flush any other previously queued meals if connection is live
      if (context != null && context.mounted) {
        flushPendingMealQueue(context);
      } else {
        flushPendingMealQueue();
      }
    }
    return result;
  }

  /// Flushes all locally pending/cached meal entries to `meals` upon connection.
  /// If [context] is provided and mounted, displays a green SnackBar on success.
  /// Returns the count of successfully synced meals.
  Future<int> flushPendingMealQueue([BuildContext? context]) async {
    if (_pendingQueue.isEmpty) return 0;
    debugPrint(
      'NutritionRepository: Flushing ${_pendingQueue.length} pending meal(s) to `meals`...',
    );

    int syncedCount = 0;
    final toSync = List<PendingMealEntry>.from(_pendingQueue);

    for (final entry in toSync) {
      final result = await _syncEntry(entry);
      if (result.isSynced) {
        _pendingQueue.remove(entry);
        syncedCount++;
      } else {
        // Stop if still offline/failing so we don't bombard network
        debugPrint(
          'NutritionRepository: Sync halted at entry "${entry.analysis.mealName}": ${result.errorMessage}',
        );
        break;
      }
    }

    debugPrint(
      'NutritionRepository: Flushed $syncedCount pending meal(s). ${_pendingQueue.length} remaining in queue.',
    );

    if (syncedCount > 0 && context != null && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Meal synced to Supabase cloud!'),
          backgroundColor: Colors.green,
          behavior: SnackBarBehavior.floating,
          duration: Duration(seconds: 3),
        ),
      );
    }

    return syncedCount;
  }

  /// Internal worker that executes the Supabase `meals` and `meal_items` insert.
  Future<SaveMealResult> _syncEntry(PendingMealEntry entry) async {
    try {
      final mealId = entry.id;
      final analysis = entry.analysis;
      final loggedAt = entry.queuedAt.toUtc().toIso8601String();
      final mealType =
          analysis.mealName.isNotEmpty ? analysis.mealName : 'Meal';

      // Average confidence score (0-100 numeric)
      double healthScore;
      if (analysis.items.isNotEmpty) {
        final avg = analysis.items
                .map((i) => i.confidence)
                .reduce((a, b) => a + b) /
            analysis.items.length;
        healthScore = (avg * 100).clamp(0.0, 100.0);
      } else {
        healthScore = (analysis.overallHealthScore <= 10.0
                ? analysis.overallHealthScore * 10.0
                : analysis.overallHealthScore)
            .clamp(0.0, 100.0);
      }

      final aiRawResponse = jsonEncode(analysis.toJson());

      // Prepare item rows for `public.meal_items`
      final itemRows = analysis.items.map((item) => {
        'meal_id': mealId,
        'weight_grams': item.weightGrams,
        'was_swiped_away': item.wasSwipedAway,
        'user_override_grams': null,
        'food_id': null,
      }).toList();

      if (mockInsertHandler != null) {
        final userId = fallbackUserId;
        await mockInsertHandler!('meals', {
          'id': mealId,
          'user_id': userId,
          'logged_at': loggedAt,
          'meal_type': mealType,
          'health_score': healthScore,
          'ai_raw_response': aiRawResponse,
        });

        if (itemRows.isNotEmpty) {
          await mockInsertHandler!('meal_items', itemRows);
        }

        return SaveMealResult(isSynced: true, mealId: mealId);
      }

      final client = customClient ?? SupabaseClientProvider.client;
      final userId = client.auth.currentUser?.id ?? fallbackUserId;

      // 1. Insert into `public.meals`
      final mealPayload = {
        'id': mealId,
        'user_id': userId,
        'logged_at': loggedAt,
        'meal_type': mealType,
        'health_score': healthScore,
        'ai_raw_response': aiRawResponse,
      };

      await client.from('meals').insert(mealPayload);

      // 2. Insert into `public.meal_items`
      if (itemRows.isNotEmpty) {
        try {
          await client.from('meal_items').insert(itemRows);
          debugPrint(
            'NutritionRepository: Synced ${itemRows.length} meal item(s) for meal $mealId to `meal_items`',
          );
        } on PostgrestException catch (e) {
          debugPrint(
            'NutritionRepository: PostgrestException inserting to `meal_items`: '
            'message: "${e.message}", code: "${e.code}", details: "${e.details}", hint: "${e.hint}"',
          );
        } catch (itemErr) {
          debugPrint(
            'NutritionRepository: Notice: meal_items insert ($itemErr)',
          );
        }
      }

      debugPrint(
        'NutritionRepository: Remote sync success for meal "${analysis.mealName}" (id: $mealId) to `meals`',
      );
      return SaveMealResult(isSynced: true, mealId: mealId);
    } on SocketException catch (e) {
      debugPrint(
        'NutritionRepository: Warning: DNS/Offline SocketException ($e). Stored in local cache.',
      );
      return SaveMealResult(isSynced: false, errorMessage: 'Offline: $e');
    } on PostgrestException catch (e) {
      debugPrint(
        'NutritionRepository: PostgrestException inserting to `meals`: '
        'message: "${e.message}", code: "${e.code}", details: "${e.details}", hint: "${e.hint}"',
      );
      return SaveMealResult(
        isSynced: false,
        errorMessage: 'Postgrest: ${e.message} (code: ${e.code})',
      );
    } catch (e) {
      debugPrint(
        'NutritionRepository: Warning: Network/Client error ($e). Stored in local cache.',
      );
      return SaveMealResult(isSynced: false, errorMessage: e.toString());
    }
  }

  /// Fetch all meals for today from `meals` table.
  Future<List<Map<String, dynamic>>> getTodayMealLogs() async {
    try {
      final client = customClient ?? SupabaseClientProvider.client;
      final today = DateTime.now().toUtc();
      final startOfDay = DateTime.utc(today.year, today.month, today.day);

      final response = await client
          .from('meals')
          .select('*, meal_items(*)')
          .gte('logged_at', startOfDay.toIso8601String())
          .order('logged_at', ascending: false);

      return List<Map<String, dynamic>>.from(response);
    } catch (e) {
      debugPrint(
        'NutritionRepository: Failed to fetch remote logs from `meals`: $e. Returning empty.',
      );
      return [];
    }
  }

  /// Fetches logged meals from Supabase `meals` table, falling back to local logs.
  Future<List<MealAnalysis>> fetchLoggedMeals() async {
    try {
      final client = customClient ?? SupabaseClientProvider.client;
      final response = await client
          .from('meals')
          .select('id, meal_type, logged_at, health_score, ai_raw_response')
          .order('logged_at', ascending: false)
          .limit(20);

      final remoteMeals = <MealAnalysis>[];
      for (final row in response) {
        if (row['ai_raw_response'] != null) {
          try {
            final decoded = jsonDecode(row['ai_raw_response'] as String);
            if (decoded is Map<String, dynamic>) {
              remoteMeals.add(MealAnalysis.fromJson(decoded));
            }
          } catch (_) {}
        }
      }
      if (remoteMeals.isNotEmpty) {
        return remoteMeals;
      }
    } catch (e) {
      debugPrint('NutritionRepository: Remote fetch failed ($e). Using local logs.');
    }
    return localMealLogs;
  }

  void dispose() {
    _authSubscription?.cancel();
  }
}
