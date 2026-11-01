> Swift extraction milestone (WIP for cross-platform release). The owner has superseded this with a Rust core. This implementation is retained as the parity reference and will move to bindings/swift/. Generated matching indices are local development outputs and excluded from Git.

# QuranRecitationKit

Offline, expected-text Qur'an recitation tracking in Swift. Give the recognizer 16 kHz mono audio and the passage you expect; consume word progress, ayah completion, transcripts, and gentle retry events.

Swift 5.9 · iOS 16+ · macOS 14+ · CPU inference through ONNX Runtime.

The engine is extracted from the recognizer used in [Hablobi](https://hablobi.app), with capture and product logic separated. This package has no account, analytics, paywall, app assets, or microphone dependency in its engine. Recognition runs locally. Only the optional model downloader uses the network.

## Status

This is the **Swift 0.1.0 implementation**. It includes two libraries, a WAV CLI, and an iOS example. Windows, Linux, Rust, Node, Python, and .NET bindings are not implemented here.

The acoustic model is **not in Git**. Before using the default downloader, the publisher must set `ModelSource.repositoryOwner` and attach the pinned model to release `model-v1`. Until then, use a local model directory or an HTTPS mirror containing the identical pinned bytes. Asset provenance qualifications are in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md); passing tests does not resolve them.

## Add the package

In Xcode, add the published repository URL as a package dependency. Select `QuranRecitationKit` and, if needed, `QuranRecitationAudio`. A package manifest uses:

```swift
.package(url: "https://github.com/YOUR_GITHUB_OWNER/QuranRecitationKit.git", from: "0.1.0")
```

```swift
.target(name: "YourApp", dependencies: [
    .product(name: "QuranRecitationKit", package: "QuranRecitationKit"),
    .product(name: "QuranRecitationAudio", package: "QuranRecitationKit")
])
```

For a local checkout, use `.package(path: "../QuranRecitationKit")`. The example already uses a local reference.

## Recognize microphone audio

Add `NSMicrophoneUsageDescription` to the host app's Info.plist. Permission is requested when capture starts.

```swift
import Foundation
import QuranRecitationKit
import QuranRecitationAudio

let pack = try ModelPack(directory: modelDirectory) // a URL; see model delivery below
let recognizer = try await RecitationRecognizer(modelPack: pack)
try await recognizer.setExpected(.surah(112))
let microphone = try RecitationMicrophone()

let updates = Task {
    for await event in recognizer.events {
        switch event {
        case .wordProgress(let word):
            print(word.ayah, word.matchedWordIndices.sorted())
        case .verseMatch(let verse):
            print("Completed", verse.surah, verse.ayah)
        case .needsRetry(let reason):
            print("Try again:", reason.rawValue)
        case .rawTranscript(let transcript):
            print(transcript.text)
        case .state(let state):
            print(state.rawValue)
        }
    }
}
try await microphone.start { chunk in await recognizer.feed(chunk) }

// Later, from the host's Stop action:
await microphone.stopAndDrain()
let summary = try await recognizer.stop()
updates.cancel()
```

Use `stopAndDrain()` before stopping the recognizer so already queued audio reaches it. Synchronous `microphone.stop()` stops capture immediately; it does not wait for queued callbacks. On iOS, `RecitationMicrophone(session:)` can use the host's AVAudioSession. macOS uses `init()` because AVAudioSession is unavailable there. The host owns audio-session deactivation and background/route UX; capture stops on interruption or engine configuration change.

If you already capture audio, skip the audio library and call `await recognizer.feed(pcm16k)` directly. Samples must be finite mono Float32 at 16 kHz; any chunk size is accepted. Feed regularly, typically 100–300 ms at a time.

## Choose a target

```swift
try await recognizer.setExpected(.surah(1))
try await recognizer.setExpected(.ayahs(surah: 2, range: 255...257))
try await recognizer.setExpected(.words(surah: 1, ayah: 7, range: 4..<9))
```

Word offsets are zero-based, ayah-relative and half-open. For a `.words` target, the completion event means the selected range completed, not that the whole ayah was recited. Invalid targets throw before replacing a valid target.

`QuranCatalog()` provides surah names, ayah counts and verbatim Arabic for host UIs:

```swift
let catalog = try QuranCatalog()
let names = catalog.surahs
let verses = catalog.ayahs(in: 112)
let words = verses[0].words
```

If displaying that text, credit the [Tanzil Project](https://tanzil.net) and preserve its notice and terms.

## Events and lifecycle

| Event | Meaning |
|---|---|
| `.wordProgress(WordProgress)` | Provisional word support: surah, ayah, zero-based wordIndex, totalWords, matchedWordIndices, confidence |
| `.verseMatch(VerseMatch)` | Selected ayah/range passed the identity, coverage and endpoint gates; includes durationSeconds |
| `.needsRetry(RetryReason)` | `.inconclusive`, `.offTarget`, `.noise`, or `.tooShort`; never a pronunciation accusation |
| `.rawTranscript(RawTranscript)` | Normalized model output, separate from the verified Quran display text |
| `.state(RecognitionState)` | `.idle`, `.listening`, `.evaluating`, `.ended` |

Confidence is an uncalibrated CTC margin, not a probability of correct recitation. Transcript confidence is 0 because this version does not calibrate it. Provisional word progress cannot authorize completion. This is **not a Tajweed assessment tool**.

Attach one consumer before capture: `events` is a single AsyncStream with a newest-256 buffer, not a multicast bus. A stalled consumer can miss intermediate events; the final summary retains completed ayahs. `stop()` ends input, supplies endpoint silence, and returns the summary. `reset()` invalidates outstanding inference. Set a target again to start another capture. Concurrent duplicate stops are rejected.

```swift
let configuration = RecitationConfiguration(
    liveTracking: true,
    maximumWindowSeconds: 12,
    backtrackWords: 3,
    lookaheadWords: 32,
    policy: .balanced
)
```

Balanced is the default legacy threshold policy. Conservative requires full word coverage and two stable endpoint cycles. Lenient shortens the endpoint floor to 200 ms while retaining the identity gate. The presets do not claim calibrated error rates. PCM retention is bounded to 2–12 seconds. See [implementation notes](docs/SWIFT-IMPLEMENTATION.md) for the ayah-based scheduling changes and limitations.

## Model delivery

A local directory must contain:

```text
fastconformer_full_mixed.onnx
model-manifest.json
```

The manifest is supplied in `Sources/QuranRecitationKit/Resources/`. The model must be exactly **88,307,457 bytes**, SHA-256 **822534428f1ed54eb802a9c43d4ecbabdfd8ba346b4d88d710414b0bbe7b4d69**. The loader pins these independently of the manifest. Do not rename an incompatible model to bypass validation.

After the publisher configures the repository and release:

```swift
let pack = try await ModelPack.download(progress: { fraction in
    print(fraction)
})
```

Default cache: Application Support/QuranRecitationKit/model-v1/. Downloads use a staging directory, size/hash validation and atomic file replacement. Corrupt cache entries are re-downloaded; interrupted bytes are never trusted. Concurrent callers share the transfer, and cancellation removes only that caller's lease until the last caller leaves. An integrator can provide a `ModelSource(url:sha256:byteCount:)` for an HTTPS mirror of the same bytes.

See [MODEL_CARD.md](MODEL_CARD.md) for provenance, tensor shapes and limitations. No real recitation audio is shipped or downloaded by this package.

## Run the CLI and example

```sh
swift run recite-cli --surah 1 --ayahs 1-1 --wav /path/to/your-recording.wav --model /path/to/model-directory
```

The CLI accepts PCM16 or Float32 WAV files at any supported source sample rate, downmixes and resamples, and feeds 300 ms chunks. It prints events and a summary. Exit code 0 means every requested ayah matched; 1 means incomplete; 2 means setup/input/runtime failure. Audio stays in its original location.

Open `Example/RecitationDemo/RecitationDemo.xcodeproj`. It includes a download card, surah picker, record/stop, word highlighting, completion checks, a gentle retry message and an input meter. Set your signing team for a device; no signing is required for the simulator build. The default download requires the release setup described above.

## Verify

```sh
swift build -v
swift test -v
python3 -m venv Tools/.venv
Tools/.venv/bin/pip install -r Tools/requirements.txt
TOKEN_MAP_PYTHON=Tools/.venv/bin/python Tools/verify_token_map.sh
xcodebuild -project Example/RecitationDemo/RecitationDemo.xcodeproj \
  -scheme RecitationDemo -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /private/tmp/HearBuild-shared CODE_SIGNING_ALLOWED=NO build
```

Tests require neither a model download nor audio. The real ONNX shape test is skipped unless `QRK_MODEL_DIR` points at an already-local model pack. Dependency resolution may need network access on the first build.

## Credits and license

Project code: MIT, Yousef Alabadi. Portions derive from [Tilawa](https://github.com/yazinsai/tilawa), MIT, source commit `ec5cdc72c1c48ba29866ca2e3197d6b9a0e2e793` (distinct from its v0.2.0 model release). NVIDIA acoustic weights/tokenizer: CC BY 4.0. Tanzil Arabic: CC BY 3.0 plus Tanzil's verbatim-only terms. ONNX Runtime: MIT. See [full notices](THIRD_PARTY_NOTICES.md), [security](SECURITY.md), and [contributing](CONTRIBUTING.md).
