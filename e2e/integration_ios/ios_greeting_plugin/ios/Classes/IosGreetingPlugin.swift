import Flutter
import UIKit

public class IosGreetingPlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "rules_flutter/ios_greeting", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(IosGreetingPlugin(), channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "getGreeting":
      result("Hello from iOS Swift plugin!")
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}
