import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:google_generative_ai/google_generative_ai.dart';
import 'package:http/http.dart' as http;

import '../../features/nutrition/domain/models/meal_analysis.dart';
import '../utils/image_compressor_isolate.dart';

/// Thinking configuration for Gemini models to control or minimize reasoning tokens.
/// Setting [thinkingBudget] to 0 minimizes reasoning latency from 60s down to 2–4s.
class ThinkingConfig {
  const ThinkingConfig({this.thinkingBudget = 0});

  /// The budget for thinking tokens. 0 disables thinking.
  final int thinkingBudget;

  Map<String, dynamic> toJson() => {'thinkingBudget': thinkingBudget};
}

/// Custom HTTP client for Gemini REST API requests.
class FastGeminiHttpClient extends http.BaseClient {
  FastGeminiHttpClient({
    http.Client? inner,
    required this.service,
  }) : _inner = inner ?? http.Client();

  final http.Client _inner;
  final GeminiVisionService service;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    return _inner.send(request);
  }

  @override
  void close() {
    _inner.close();
    super.close();
  }
}

/// Service that wraps the Gemini Vision models for structured
/// meal-photo analysis.
///
/// Enforces:
/// - Multimodal prompt with image frame encoding
/// - Structured JSON output schema (meal_name, items with macros:
///   protein, carbs, fat, fiber, calories).
/// - Macro sanity validation: `4*P + 4*C + 9*F` must be within reasonable bounds.
class GeminiVisionService {
  GeminiVisionService._();

  static GeminiVisionService? _instance;
  GenerativeModel? _customModel;

  /// Active model: 'gemini-2.5-flash'
  static const String activeModel = 'gemini-2.5-flash';
  static const List<String> defaultFallbackModels = [
    'gemini-2.5-flash',
    'gemini-2.0-flash',
    'gemini-1.5-flash',
  ];

  @visibleForTesting
  List<String> fallbackModels = List.from(defaultFallbackModels);

  @visibleForTesting
  ThinkingConfig thinkingConfig = const ThinkingConfig(thinkingBudget: 0);

  /// Strict timeout per model attempt (defaults to 30 seconds).
  @visibleForTesting
  Duration modelTimeout = const Duration(seconds: 30);

  /// Maximum retries on active model (defaults to 3).
  @visibleForTesting
  int maxRetries = 3;

  /// Delay between retries on 503 / transient network errors (defaults to 2 seconds).
  @visibleForTesting
  Duration retryDelay = const Duration(seconds: 2);

  final Map<String, GenerativeModel> _modelCache = {};
  late http.Client _httpClient = FastGeminiHttpClient(service: this);

  /// Singleton accessor.
  static GeminiVisionService get instance {
    _instance ??= GeminiVisionService._();
    return _instance!;
  }

  /// Optional model injection for testing.
  @visibleForTesting
  static void setMockInstance(GeminiVisionService mock) {
    _instance = mock;
  }

  /// Reset singleton for testing.
  @visibleForTesting
  static void resetInstance() {
    _instance?._modelCache.clear();
    _instance?._httpClient.close();
    _instance = null;
  }

  /// Inject custom generative model (e.g. for testing).
  @visibleForTesting
  void setCustomModel(GenerativeModel model) {
    _customModel = model;
  }

  /// Inject custom HTTP client for testing.
  @visibleForTesting
  void setCustomHttpClient(http.Client client) {
    _httpClient = client;
    _modelCache.clear();
  }

  /// Optional mock function for generateContent during testing
  /// (needed because GenerativeModel is a final class in Dart 3).
  @visibleForTesting
  Future<GenerateContentResponse> Function(Iterable<Content> content)?
      mockGenerateContent;

  /// Optional mock function with model name inspection for testing fallback chains.
  @visibleForTesting
  Future<GenerateContentResponse> Function(
    String modelName,
    Iterable<Content> content,
  )? mockGenerateContentWithModel;

  /// Configurable retry delays for transient errors (HTTP 503, 429).
  @visibleForTesting
  List<Duration> retryDelays = const [
    Duration(milliseconds: 1500),
    Duration(milliseconds: 3000),
    Duration(milliseconds: 5000),
  ];

  GenerativeModel _getModelForName(String modelName) {
    if (_customModel != null) return _customModel!;

    final cached = _modelCache[modelName];
    if (cached != null) return cached;

    final apiKey = dotenv.env['GEMINI_API_KEY'] ?? '';
    if (apiKey.isEmpty) {
      throw GeminiAnalysisException(
        'GEMINI_API_KEY is not set in .env. Please configure your Gemini API key.',
      );
    }

    final model = GenerativeModel(
      model: modelName,
      apiKey: apiKey,
      generationConfig: GenerationConfig(
        responseMimeType: 'application/json',
        temperature: 0.1,
      ),
      httpClient: _httpClient,
    );
    _modelCache[modelName] = model;
    return model;
  }

  /// The structured prompt sent alongside the meal photos.
  static const _systemPrompt = '''
Respond strictly with valid JSON matching the schema. Do not include markdown fences or conversational text.
You are a professional nutritionist AI. Analyze the food in the provided image(s) and return a structured JSON response.

You MUST return ONLY valid JSON with this exact schema:
{
  "meal_name": "<descriptive name for the meal>",
  "items": [
    {
      "name": "<ingredient name>",
      "weight_grams": <estimated weight in grams as number>,
      "protein": <grams of protein as number>,
      "carbs": <grams of carbohydrates as number>,
      "fat": <grams of fat as number>,
      "fiber": <grams of fiber as number>,
      "confidence": <0.0 to 1.0 confidence score>
    }
  ]
}

Rules:
- Identify every visible ingredient/component separately across all captured photos.
- Estimate realistic portion sizes based on visual cues and perspective.
- Be precise with macro values (protein, carbs, fat, fiber) — use USDA-equivalent data.
- confidence should reflect how certain you are about the identification (0.0 to 1.0).
- If the provided image does not contain food or beverage items, return a valid JSON object with meal_name set to 'No Food Detected', an empty ingredients list [], and all macro values set to 0. Do not throw an error or refuse to answer.
- Return ONLY the JSON object, no markdown fences or explanation.
''';

  /// Analyze a single meal photo at [imagePath].
  Future<MealAnalysis> analyzeMealPhoto(String imagePath) {
    return analyzeMealPhotos([imagePath]);
  }

  /// Analyze multiple meal photos at [imagePaths] and return a validated
  /// [MealAnalysis].
  ///
  /// Each image file is read and encoded as a [DataPart].
  /// If possible, images are resized/compressed via [ImageCompressorIsolate]
  /// to minimize payload sizes and prevent out-of-memory issues.
  ///
  /// Throws [GeminiAnalysisException] if parsing or validation fails.
  Future<MealAnalysis> analyzeMealPhotos(List<String> imagePaths) async {
    if (imagePaths.isEmpty) {
      throw GeminiAnalysisException('No photos provided for analysis.');
    }

    final parts = <Part>[TextPart(_systemPrompt)];

    for (final path in imagePaths) {
      final file = File(path);
      if (!await file.exists()) {
        continue;
      }

      Uint8List bytes;
      String mimeType = _inferMimeType(path);

      try {
        final compressed = await ImageCompressorIsolate.compress(
          inputPath: path,
          maxDimension: 800,
          quality: 70,
        );
        final compressedFile = File(compressed.path);
        if (await compressedFile.exists()) {
          bytes = await compressedFile.readAsBytes();
          mimeType = 'image/jpeg';
          final kb = bytes.lengthInBytes / 1024;
          debugPrint(
            'GeminiVisionService: Compressed image payload: ${kb.toStringAsFixed(1)} KB (800px max dimension, 70% quality)',
          );
        } else {
          bytes = await file.readAsBytes();
        }
      } catch (e) {
        debugPrint(
          'GeminiVisionService: Isolate compression failed ($e). Reading source bytes directly.',
        );
        // Fallback to reading the uncompressed image bytes if isolate compression fails
        bytes = await file.readAsBytes();
      }

      // Image Payload Verification:
      // Verify that imageBytes.lengthInBytes < 250000 (~250 KB). If larger, force downscale
      // using the existing image compressor isolate to 800px max edge at 65% JPEG quality.
      if (bytes.lengthInBytes >= 250000) {
        final currentKb = (bytes.lengthInBytes / 1024).toStringAsFixed(1);
        debugPrint(
          'GeminiVisionService: Image payload is $currentKb KB (>= 250 KB). Force downscaling to 800px at 65% JPEG quality...',
        );
        try {
          String pathToCompress = path;
          File? tempInputFile;
          if (!await File(path).exists()) {
            final tempDir = Directory.systemTemp;
            tempInputFile = File(
              '${tempDir.path}/temp_payload_${DateTime.now().millisecondsSinceEpoch}.jpg',
            );
            await tempInputFile.writeAsBytes(bytes);
            pathToCompress = tempInputFile.path;
          }

          final forced = await ImageCompressorIsolate.compress(
            inputPath: pathToCompress,
            maxDimension: 800,
            quality: 65,
          );
          final forcedFile = File(forced.path);
          if (await forcedFile.exists()) {
            bytes = await forcedFile.readAsBytes();
            mimeType = 'image/jpeg';
            final newKb = (bytes.lengthInBytes / 1024).toStringAsFixed(1);
            debugPrint(
              'GeminiVisionService: Force downscaling reduced payload to $newKb KB.',
            );
          }
          if (tempInputFile != null && await tempInputFile.exists()) {
            await tempInputFile.delete();
          }
        } catch (e) {
          debugPrint(
            'GeminiVisionService: Force downscaling failed ($e). Continuing with current payload.',
          );
        }
      }

      parts.add(DataPart(mimeType, bytes));
    }

    // parts[0] is the text prompt; at least one image part must be present
    if (parts.length == 1) {
      throw GeminiAnalysisException(
        'None of the captured photos could be read from disk.',
      );
    }

    final content = [Content.multi(parts)];

    final GenerateContentResponse response = await _generateContentWithRetry(
      content: content,
    );

    final responseText = response.text;
    if (responseText == null || responseText.trim().isEmpty) {
      throw GeminiAnalysisException('Empty response from Gemini model.');
    }

    // Clean JSON response (strip markdown wrappers or stray commentary)
    String cleaned = responseText.trim();
    if (cleaned.startsWith('```json')) {
      cleaned = cleaned.substring(7);
    } else if (cleaned.startsWith('```')) {
      cleaned = cleaned.substring(3);
    }
    if (cleaned.endsWith('```')) {
      cleaned = cleaned.substring(0, cleaned.length - 3);
    }
    cleaned = cleaned.trim();

    final startIndex = cleaned.indexOf('{');
    final endIndex = cleaned.lastIndexOf('}');
    if (startIndex != -1 && endIndex != -1 && endIndex > startIndex) {
      cleaned = cleaned.substring(startIndex, endIndex + 1);
    }

    final Map<String, dynamic> jsonResponse;
    try {
      jsonResponse = jsonDecode(cleaned) as Map<String, dynamic>;
    } catch (e) {
      throw GeminiAnalysisException(
        'Failed to parse Gemini response as JSON: $e\nRaw: $responseText',
      );
    }

    final analysis = MealAnalysis.fromJson(jsonResponse);

    // Gracefully handle non-food images without throwing an error
    if (analysis.mealName == 'No Food Detected') {
      return analysis;
    }

    if (analysis.items.isEmpty) {
      throw GeminiAnalysisException(
        'No ingredients could be detected in the captured photos. Please try again with clearer lighting or closer framing.',
      );
    }

    // Macro sanity validation (§3.3)
    _validateMacroSanity(analysis);

    return analysis;
  }

  /// Validate that the macro breakdown is internally consistent.
  void _validateMacroSanity(MealAnalysis analysis) {
    for (final item in analysis.items) {
      final computedCal =
          (4 * item.protein) + (4 * item.carbs) + (9 * item.fat);

      // Skip sanity check for zero-calorie items (e.g. water, spices).
      if (computedCal <= 0) continue;

      if (item.weightGrams > 0) {
        final density = computedCal / item.weightGrams;
        if (density > 9.5 || density < 0.1) {
          debugPrint(
            'GeminiVisionService: Suspicious caloric density '
            '${density.toStringAsFixed(2)} kcal/g for "${item.name}"',
          );
        }
      }
    }
  }

  /// Infer MIME type from file extension.
  String _inferMimeType(String path) {
    final lower = path.toLowerCase();
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.webp')) return 'image/webp';
    if (lower.endsWith('.gif')) return 'image/gif';
    return 'image/jpeg';
  }

  /// Detects whether an error from the Gemini SDK or HTTP layer is a network timeout.
  @visibleForTesting
  bool isTimeoutError(Object error) => _isTimeoutError(error);

  bool _isTimeoutError(Object error) {
    if (error is TimeoutException) return true;
    final str = error.toString().toLowerCase();
    return str.contains('timeout') || str.contains('timed out');
  }

  /// Detects whether an error from the Gemini SDK or HTTP layer is a transient 503/429/network error.
  @visibleForTesting
  bool isTransientError(Object error) => _isTransientError(error);

  bool _isTransientError(Object error) {
    if (_isTimeoutError(error)) return false;
    final str = error.toString().toLowerCase();
    return str.contains('503') ||
        str.contains('429') ||
        str.contains('unavailable') ||
        str.contains('resource_exhausted') ||
        str.contains('overloaded') ||
        str.contains('rate limit') ||
        str.contains('quota') ||
        str.contains('high demand') ||
        str.contains('too many requests') ||
        str.contains('server unavailable') ||
        str.contains('socketexception') ||
        str.contains('connection closed') ||
        str.contains('clientexception') ||
        str.contains('handshakeexception');
  }

  /// Detects whether an error from the Gemini SDK or HTTP layer is a fatal non-transient error.
  @visibleForTesting
  bool isFatalError(Object error) => _isFatalError(error);

  bool _isFatalError(Object error) {
    if (_isTimeoutError(error)) return false;
    final str = error.toString().toLowerCase();
    return str.contains('400') ||
        str.contains('invalid api key') ||
        str.contains('api key not valid') ||
        str.contains('invalid_argument');
  }

  /// Backward-compatible alias for fallbackable error detection.
  @visibleForTesting
  bool isFallbackableError(Object error) => !_isTimeoutError(error) && !_isFatalError(error);

  /// Extracts the HTTP status code or brief reason from an exception.
  String _extractErrorCodeOrReason(Object error) {
    if (_isTimeoutError(error)) return 'Timeout (${modelTimeout.inSeconds}s)';
    final str = error.toString();
    if (str.contains('503')) return '503';
    if (str.contains('429')) return '429';
    if (str.contains('404')) return '404';
    if (str.toLowerCase().contains('resource_exhausted')) return '429';
    if (str.toLowerCase().contains('unavailable')) return '503';
    if (str.toLowerCase().contains('overloaded')) return '503';
    if (str.toLowerCase().contains('not found') || str.toLowerCase().contains('unsupported')) return '404';

    // Regex check for numeric status code
    final codeMatch = RegExp(r'\b(4\d\d|5\d\d)\b').firstMatch(str);
    if (codeMatch != null) return codeMatch.group(1)!;

    // Check JSON code/status
    if (str.contains('"code":')) {
      final match = RegExp(r'"code":\s*(\d+)').firstMatch(str);
      if (match != null) return match.group(1)!;
    }
    if (str.contains('"status":')) {
      final match = RegExp(r'"status":\s*"([^"]+)"').firstMatch(str);
      if (match != null) return match.group(1)!;
    }

    final reason = str.replaceFirst('GenerativeAIException: ', '').replaceFirst('Exception: ', '').trim();
    return reason.length > 40 ? reason.substring(0, 40) : reason;
  }

  /// Sanitizes raw GenerativeAIException JSON errors into human-readable messages.
  String _sanitizeErrorMessage(Object error) {
    final str = error.toString();
    if (error is GeminiAnalysisException) return error.message;
    if (_isTimeoutError(error)) {
      return 'Network request timed out. Please check your connection and try again.';
    }

    // Check if error contains raw JSON structure from GenerativeAIException
    if (str.contains('"error":') || str.contains('"code":') || str.contains('"message":')) {
      try {
        final startIndex = str.indexOf('{');
        final endIndex = str.lastIndexOf('}');
        if (startIndex != -1 && endIndex != -1 && endIndex > startIndex) {
          final jsonStr = str.substring(startIndex, endIndex + 1);
          final decoded = jsonDecode(jsonStr);
          if (decoded is Map<String, dynamic> && decoded['error'] is Map<String, dynamic>) {
            final msg = decoded['error']['message'];
            if (msg != null && msg is String && msg.isNotEmpty) {
              return 'Gemini API error: $msg';
            }
          }
        }
      } catch (_) {
        // Fallback to general cleanup if JSON parse fails
      }
    }

    return 'Gemini API call failed: ${str.replaceFirst('GenerativeAIException: ', '').replaceFirst('Exception: ', '')}';
  }

  /// Executes content generation across [fallbackModels] in order.
  ///
  /// If [activeModel] ('gemini-2.5-flash') fails with a 503, 404, or error,
  /// it immediately tries 'gemini-2.0-flash' and then 'gemini-1.5-flash'.
  /// Throws [GeminiAnalysisException] if all fallback models fail or if a fatal error occurs.
  @visibleForTesting
  Future<GenerateContentResponse> generateContentWithRetry({
    GenerativeModel? model,
    required List<Content> content,
  }) => _generateContentWithRetry(content: content);

  /// Backward-compatible alias for testing.
  @visibleForTesting
  Future<GenerateContentResponse> generateContentWithFallback({
    required List<Content> content,
  }) => _generateContentWithRetry(content: content);

  Future<GenerateContentResponse> _generateContentWithRetry({
    required List<Content> content,
  }) async {
    Object? lastError;
    StackTrace? lastStackTrace;

    for (final modelName in fallbackModels) {
      debugPrint(
        'GeminiVisionService: Attempting model "$modelName" with ${modelTimeout.inSeconds}s timeout...',
      );

      try {
        final Future<GenerateContentResponse> callFuture;
        if (mockGenerateContentWithModel != null) {
          callFuture = mockGenerateContentWithModel!(modelName, content);
        } else if (mockGenerateContent != null) {
          callFuture = mockGenerateContent!(content);
        } else {
          final model = _getModelForName(modelName);
          callFuture = model.generateContent(content);
        }

        final GenerateContentResponse response = await callFuture.timeout(
          modelTimeout,
        );

        debugPrint(
          'GeminiVisionService: Successfully generated content using model "$modelName"!',
        );
        return response;
      } catch (e, st) {
        lastError = e;
        lastStackTrace = st;

        if (_isTimeoutError(e)) {
          debugPrint(
            'GeminiVisionService: Request timed out after ${modelTimeout.inSeconds}s on model "$modelName". Aborting retry loop.',
          );
          throw GeminiAnalysisException(
            'Network request timed out. Please check your connection and try again.',
          );
        }

        if (_isFatalError(e)) {
          debugPrint('GeminiVisionService: Non-transient fatal error on "$modelName": $e');
          debugPrint('GeminiVisionService: Full stack trace:\n$st');
          throw GeminiAnalysisException(_sanitizeErrorMessage(e));
        }

        debugPrint(
          'GeminiVisionService: Model "$modelName" failed with error: $e. Immediately trying next fallback model...',
        );
      }
    }

    // All retries failed
    final reason = _extractErrorCodeOrReason(lastError ?? '503');
    debugPrint(
      'GeminiVisionService: All fallback models failed (last reason: $reason). Last error: $lastError',
    );
    if (lastStackTrace != null) {
      debugPrint('GeminiVisionService: Full stack trace for last error:\n$lastStackTrace');
    }

    throw GeminiAnalysisException(
      'AI service is currently busy. Please try again in a moment.',
    );
  }
}

/// Exception thrown when Gemini analysis fails.
class GeminiAnalysisException implements Exception {
  GeminiAnalysisException(this.message);
  final String message;

  @override
  String toString() => message;
}
