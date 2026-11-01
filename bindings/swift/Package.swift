// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "QuranRecitationKit", platforms: [.iOS(.v16), .macOS(.v14)],
    products: [.library(name: "QuranRecitationKit", targets: ["QuranRecitationKit"]), .library(name: "QuranRecitationAudio", targets: ["QuranRecitationAudio"]), .executable(name: "recite-cli", targets: ["recite-cli"])],
    dependencies: [.package(url: "https://github.com/microsoft/onnxruntime-swift-package-manager", from: "1.24.0")],
    targets: [
        .target(name: "QuranRecitationKit", dependencies: [.product(name: "onnxruntime", package: "onnxruntime-swift-package-manager")], resources: [.process("Resources")]),
        .target(name: "QuranRecitationAudio", dependencies: ["QuranRecitationKit"]),
        .executableTarget(name: "recite-cli", dependencies: ["QuranRecitationKit", "QuranRecitationAudio"], path: "Tools/recite-cli"),
        .testTarget(name: "QuranRecitationKitTests", dependencies: ["QuranRecitationKit", "QuranRecitationAudio"])
    ])
