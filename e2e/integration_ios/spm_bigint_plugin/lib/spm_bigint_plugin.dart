import 'package:flutter/services.dart';

/// Method-channel client for the native BigInt plugin.
class SpmBigintPlugin {
  /// Creates a [SpmBigintPlugin] instance.
  const SpmBigintPlugin();

  static const MethodChannel _channel = MethodChannel(
    'rules_flutter/spm_bigint',
  );

  /// Asks the native side to compute `2^100` and `-0` with BigInt at run
  /// time, proving the plugin's SwiftPM product linked into its Apple
  /// library.
  Future<String?> computeBig() {
    return _channel.invokeMethod<String>('computeBig');
  }
}
