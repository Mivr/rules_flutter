import UIKit

/// Entry point of the SwiftPM consumer app: `@main` synthesizes `main` so the
/// `ios_application` in `//:swiftpm_consumer_app` links. The app is never
/// launched; the simulator build test only builds it. Calling
/// `bigPowerOfTwo()` at launch keeps the BigInt use in the linked binary
/// instead of letting the linker dead-strip it.
@main
class SwiftPMConsumerAppDelegate: UIResponder, UIApplicationDelegate {
  func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    _ = bigPowerOfTwo()
    return true
  }
}
