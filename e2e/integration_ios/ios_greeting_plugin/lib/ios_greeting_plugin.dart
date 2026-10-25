import 'package:flutter/services.dart';

/// Method-channel client for the native iOS Swift greeting plugin.
class IosGreetingPlugin {
  /// Creates an [IosGreetingPlugin] instance.
  const IosGreetingPlugin();

  static const MethodChannel _channel = MethodChannel(
    'rules_flutter/ios_greeting',
  );

  /// Requests the greeting string from the native iOS Swift plugin.
  Future<String?> getGreeting() {
    return _channel.invokeMethod<String>('getGreeting');
  }
}
