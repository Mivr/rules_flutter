// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "spm_bigint_plugin",
    platforms: [
        .iOS("12.0")
    ],
    products: [
        .library(name: "spm_bigint_plugin", targets: ["spm_bigint_plugin"])
    ],
    dependencies: [
        .package(url: "https://github.com/attaswift/BigInt.git", exact: "6.0.1")
    ],
    targets: [
        .target(
            name: "spm_bigint_plugin",
            dependencies: [.product(name: "BigInt", package: "BigInt")]
        )
    ]
)
