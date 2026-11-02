// swift-tools-version: 5.9
import PackageDescription
import Foundation
let root = URL(fileURLWithPath: Context.packageDirectory, isDirectory: true)
let prefix = "bindings/swift/"
let local = prefix + "Artifacts/QRKFFI.xcframework"
let binary: Target
if FileManager.default.fileExists(atPath: root.appendingPathComponent(local).path) {
    binary = .binaryTarget(name: "QRKFFI", path: local)
} else {
    // Generated release pin: version resolution evaluates this file without a source checkout.
    binary = .binaryTarget(name: "QRKFFI", url: "https://github.com/yvezf/QuranRecitationKit/releases/download/v0.2.1/QRKFFI.xcframework.zip", checksum: "ad7f79e7cdbac3c41cc1453232da518f67adf4dc4d99774444bd37a1aa9ab38e")
}
let package = Package(
    name: "QuranRecitationKit", platforms: [.iOS(.v16), .macOS(.v14)],
    products: [.library(name: "QuranRecitationKit", targets: ["QuranRecitationKit"]),
        .library(name: "QuranRecitationAudio", targets: ["QuranRecitationAudio"]),
        .executable(name: "recite-cli", targets: ["recite-cli"])],
    targets: [binary,
        .target(name: "QuranRecitationKit", dependencies: ["QRKFFI"], path: prefix + "Sources/QuranRecitationKit", resources: [.process("Resources")],
            linkerSettings: [.linkedLibrary("c++"), .linkedLibrary("iconv"),
                .linkedFramework("Foundation"), .linkedFramework("Security"),
                .linkedFramework("CoreML"), .linkedFramework("Accelerate")]),
        .target(name: "QuranRecitationAudio", dependencies: ["QuranRecitationKit"], path: prefix + "Sources/QuranRecitationAudio"),
        .executableTarget(name: "recite-cli", dependencies: ["QuranRecitationKit", "QuranRecitationAudio"], path: prefix + "Tools/recite-cli"),
        .testTarget(name: "QuranRecitationKitTests", dependencies: ["QuranRecitationKit", "QuranRecitationAudio"], path: prefix + "Tests/QuranRecitationKitTests")])
