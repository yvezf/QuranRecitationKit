// swift-tools-version: 5.9
import PackageDescription
import Foundation
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let prefix = "bindings/swift/"
let local = prefix + "Artifacts/QRKFFI.xcframework"
let binary: Target
if FileManager.default.fileExists(atPath: root.appendingPathComponent(local).path) {
    binary = .binaryTarget(name: "QRKFFI", path: local)
} else {
    let metadata = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent(prefix + "binary-release.json"))) as! [String: Any]
    guard let url = metadata["url"] as? String, let checksum = metadata["checksum"] as? String else {
        fatalError("Native archive not built or release-pinned. Run python3 tools/build_xcframework.py from the repository root; publisher: see docs/RELEASING.md.")
    }
    binary = .binaryTarget(name: "QRKFFI", url: url, checksum: checksum)
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
