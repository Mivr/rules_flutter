import BigInt

/// Exercises the translated SwiftPM product: `BigUInt.power` comes from the
/// `bigint` spoke's `swift_library`, so building this module builds BigInt
/// for the iOS simulator.
public func bigPowerOfTwo() -> String {
    return String(BigUInt(2).power(100))
}
