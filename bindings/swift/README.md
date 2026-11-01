# Swift binding

Swift 5.9+, iOS 16+, macOS 14+. Thin actor wrapper around the same Rust C ABI. AVAudioEngine capture remains a separate `QuranRecitationAudio` product. No app UI, backend, subscription, ODR or model weights are required.

For a prebuilt dependency, add `.package(url: "https://github.com/yvezfscarves-afk/QuranRecitationKit.git", from: "0.1.1")` and choose the engine/audio products. The release archive is publicly available and checksum-pinned. To rebuild the native archive from source, run `python3 tools/build_xcframework.py` at the repository root, then `swift test --package-path bindings/swift`. The tool uses the pinned Microsoft 1.24.2 static runtime and builds iOS arm64, iOS Simulator arm64/x64, and macOS arm64/x64. The built binary is ignored, not checked into Git. The root Swift Package uses the published, pinned release; see `docs/RELEASING.md`.

```swift
import QuranRecitationKit
let model = try ModelPack(directory: modelDirectoryURL)
let recognizer = try await RecitationRecognizer(modelPack: model)
let reader = Task { for await event in recognizer.events { print(event) } }
try await recognizer.setExpected(.surah(112))
await recognizer.feed(pcm16k) // [Float], mono 16 kHz
let summary = try await recognizer.stop()
reader.cancel()
```

The five verbs retain the approved Swift API: initializer, setExpected, feed, stop, reset. `events` is an AsyncStream; consume it promptly (512 recent events buffered). The returned summary retains all accepted verses; highlighting is provisional. feed/reset are non-throwing for compatibility; inspect actor-isolated `lastError` if a native transport error occurs. stop/setExpected throw. An instance may be reset for another passage; stop does not finish its event stream.

`ModelPack.download(from:to:progress:)` is explicit, checks pinned size/hash, and shares concurrent cache downloads. A cancelled caller does not cancel another caller's shared download. The default model URL points to the public model-v1 release. HTTPS mirrors must contain the exact same pinned model. The release owner/metadata come from Rust, not a second Swift constant.

`QuranCatalog` exposes verbatim Arabic for display. Its word array slices the unnumbered basmala from first ayahs where required, preserving source characters. No generated normalized Quran index is packaged. `examples/swift-ios/` shows the microphone adapter, permission description, model-download state and word highlighting. The host owns its audio-session lifecycle; no permission is requested during engine creation.
