import 'package:flutter/services.dart';

/// Method-channel client for the native iOS app-identity plugin.
class IosGreetingPlugin {
  /// Creates an [IosGreetingPlugin] instance.
  const IosGreetingPlugin();

  static const MethodChannel _channel = MethodChannel(
    'rules_flutter/ios_greeting',
  );

  /// Requests the enclosing app's bundle identifier from the native iOS
  /// plugin, which reads it off `Bundle.main`.
  Future<String?> getAppBundleId() {
    return _channel.invokeMethod<String>('getAppBundleId');
  }
}
