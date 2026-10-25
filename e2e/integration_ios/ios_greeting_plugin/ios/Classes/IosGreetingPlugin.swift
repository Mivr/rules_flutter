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
    // The app's own bundle identifier, read from the native bundle object.
    // The Dart side has no API for this (nothing in scope reports the
    // enclosing app's id), so the rule-assigned id is only observable
    // through this channel: the test checks it against the `ios_bundle_id`
    // default, proving the installed app is the one the rule built.
    case "getAppBundleId":
      result(Bundle.main.bundleIdentifier)
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}
