import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Singleton access to the initialized Supabase client.
///
/// [initSupabase] must be called once during app startup (in `main()`)
/// before any feature code accesses the client.
class SupabaseClientProvider {
  SupabaseClientProvider._();

  static SupabaseClient get client => Supabase.instance.client;

  /// Initialize Supabase using credentials from `.env`.
  ///
  /// Reads `SUPABASE_URL` and `SUPABASE_ANON_KEY` from flutter_dotenv.
  /// Throws [AssertionError] if either value is missing.
  static Future<void> init() async {
    final url = dotenv.env['SUPABASE_URL'];
    final anonKey = dotenv.env['SUPABASE_ANON_KEY'];

    assert(url != null && url.isNotEmpty, 'SUPABASE_URL is not set in .env');
    assert(
      anonKey != null && anonKey.isNotEmpty,
      'SUPABASE_ANON_KEY is not set in .env',
    );

    await Supabase.initialize(
      url: url!,
      // ignore: deprecated_member_use
      anonKey: anonKey!,
    );
  }
}
