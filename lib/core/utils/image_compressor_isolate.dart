import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';

/// Result of an image compression operation.
///
/// Contains the [path] to the compressed file on disk and its [sizeBytes].
class CompressedImageResult {
  const CompressedImageResult({required this.path, required this.sizeBytes});

  final String path;
  final int sizeBytes;
}

/// Parameters passed into the compression isolate.
///
/// We avoid passing raw bytes across the isolate boundary — only
/// file paths are exchanged to maintain memory safety (Section 1.4).
class _CompressParams {
  const _CompressParams({
    required this.inputPath,
    required this.outputPath,
    required this.maxDimension,
    required this.quality,
  });

  final String inputPath;
  final String outputPath;
  final int maxDimension;
  final int quality;
}

/// Compresses and resizes meal photos in a background [Isolate].
///
/// **Memory Safety**: Raw image bytes are never loaded into the main
/// Dart heap. All I/O happens inside the isolate using disk file paths
/// (architectural invariant §1.4).
///
/// Output is capped at [maxDimension]×[maxDimension] pixels and
/// encoded as JPEG to minimize payload sizes for Gemini Vision API.
class ImageCompressorIsolate {
  ImageCompressorIsolate._();

  /// Compress the image at [inputPath] to max [maxDimension]px and
  /// [quality]% JPEG, writing the result to a temporary file.
  ///
  /// Returns a [CompressedImageResult] with the output path and size.
  static Future<CompressedImageResult> compress({
    required String inputPath,
    int maxDimension = 800,
    int quality = 70,
  }) async {
    String tempPath;
    try {
      final tempDir = await getTemporaryDirectory();
      tempPath = tempDir.path;
    } catch (_) {
      tempPath = Directory.systemTemp.path;
    }
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final outputPath = '$tempPath/compressed_$timestamp.jpg';

    final params = _CompressParams(
      inputPath: inputPath,
      outputPath: outputPath,
      maxDimension: maxDimension,
      quality: quality,
    );

    await Isolate.run(() => _compressInIsolate(params));

    final outputFile = File(outputPath);
    final sizeBytes = await outputFile.length();

    if (sizeBytes > 300 * 1024) {
      debugPrint(
        'ImageCompressorIsolate: Warning: compressed image exceeds 300KB (${(sizeBytes / 1024).toStringAsFixed(1)} KB).',
      );
    }

    return CompressedImageResult(path: outputPath, sizeBytes: sizeBytes);
  }

  /// The actual compression work, executed inside an isolate.
  ///
  /// Reads from disk, resizes, encodes, and writes back to disk.
  /// No raw byte arrays leak into the main isolate's heap.
  static void _compressInIsolate(_CompressParams params) {
    final inputFile = File(params.inputPath);
    final bytes = inputFile.readAsBytesSync();

    final decoded = img.decodeImage(bytes);
    if (decoded == null) {
      throw Exception(
        'ImageCompressorIsolate: Failed to decode image at ${params.inputPath}',
      );
    }

    // Resize only if the image exceeds maxDimension on either axis.
    img.Image resized;
    if (decoded.width > params.maxDimension ||
        decoded.height > params.maxDimension) {
      if (decoded.width >= decoded.height) {
        resized = img.copyResize(decoded, width: params.maxDimension);
      } else {
        resized = img.copyResize(decoded, height: params.maxDimension);
      }
    } else {
      resized = decoded;
    }

    final encoded = img.encodeJpg(resized, quality: params.quality);

    final outputFile = File(params.outputPath);
    outputFile.writeAsBytesSync(encoded);
  }
}
