import BigInt
import Flutter
import UIKit

public class SpmBigintPlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "rules_flutter/spm_bigint", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(SpmBigintPlugin(), channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    // Computed with the linked BigInt product at run time, so the test
    // proves the product made it into this library's link.
    case "computeBig":
      result("\(BigUInt(2).power(100)) \(BigInt("-0", radix: 10)!)")
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}
