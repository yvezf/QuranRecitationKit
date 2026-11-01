# Swift implementation, 0.1.0

This document describes the implemented Swift package. Cross-platform work in other planning documents is not part of this package's verified API.

## Products

- `QuranRecitationKit`: actor-based recognition, read-only `QuranCatalog`, model integrity and optional model delivery.
- `QuranRecitationAudio`: optional microphone capture and streaming mono resampling.
- `recite-cli`: WAV-file runner on macOS.
- `Example/RecitationDemo`: iOS 16 SwiftUI example using the package by relative path.

Swift 5.9; iOS 16; macOS 14. Dependency range: ONNX Runtime >=1.24.0, <2; the checked-in resolution is 1.24.2.

## Integration

```swift
import QuranRecitationKit
import QuranRecitationAudio

let pack = try ModelPack(directory: modelDirectory) // URL containing the model and manifest
let recognizer = try await RecitationRecognizer(modelPack: pack)
try await recognizer.setExpected(.surah(112))
let microphone = try RecitationMicrophone()
let updates = Task {
    for await event in recognizer.events {
        switch event {
        case .wordProgress(let word): print(word.ayah, word.matchedWordIndices.sorted())
        case .verseMatch(let verse): print("Completed", verse.ayah)
        case .needsRetry(let reason): print(reason.rawValue)
        case .rawTranscript(let transcript): print(transcript.text)
        case .state(let state): print(state.rawValue)
        }
    }
}
try await microphone.start { chunk in await recognizer.feed(chunk) }
// Later, from a user action:
await microphone.stopAndDrain()
let summary = try await recognizer.stop()
updates.cancel()
```

Capture requires the host's `NSMicrophoneUsageDescription` and user permission. Use `stopAndDrain()` before `recognizer.stop()` to preserve the final buffered microphone chunks; `stop()` is synchronous and is intended for immediate capture shutdown. The host owns audio-session deactivation and background/route policy. On iOS `RecitationMicrophone(session:)` optionally accepts an AVAudioSession; macOS uses `init()` because that platform has no AVAudioSession.

The model file is not committed. `ModelPack(directory:)` requires `fastconformer_full_mixed.onnx` and `model-manifest.json` with the pinned size and hash. `ModelPack.download()` requires setting the single `ModelSource.repositoryOwner` constant and publishing the corresponding GitHub Release first. A custom `ModelSource` can select an HTTPS mirror of the same pinned bytes, not an arbitrary incompatible acoustic model. The example's download card will show a configuration error until that release exists.

## Targets and indices

```swift
try await recognizer.setExpected(.surah(1))
try await recognizer.setExpected(.ayahs(surah: 2, range: 255...257))
try await recognizer.setExpected(.words(surah: 1, ayah: 7, range: 4..<9))
```

Word offsets are zero-based and ayah-relative. `QuranCatalog().ayahs(in:)` supplies verbatim display Arabic and semantic words matching these offsets. Only selected ayahs/ranges can complete. For a `.words` target, `verseMatch` denotes completion of that selected range, not a claim that the entire ayah was recited.

`WordProgress` is provisional acoustic/text support; it is not completion authority. `VerseMatch` requires the identity/coverage/endpoint policy. Confidence is a bounded CTC target margin, not a calibrated probability or Tajweed verdict. Raw transcript confidence is 0 (uncalibrated), and raw text is model output, never a replacement for verified display text.

Attach one consumer to `events` before capture. It is one AsyncStream, not a multicast bus, with a bounded newest-256 buffer. A stalled consumer can miss intermediate events; `stop()` returns the retained completion summary. `reset()` invalidates outstanding results and returns to idle. `stop()` ends input and supplies zero endpoint padding only; it never manufactures text evidence. Call `setExpected` to start a fresh capture after stopping.

## Execution

PCM is retained in a fixed-capacity 12-second ring. An immutable snapshot is offered every 3,200 fresh samples. One completion-driven worker consumes a newest-in-window slot and a terminal slot. Generation checks discard work after reset/retarget; ONNX objects remain on the original runner's serial queues. The runner's bounded FIFO, task leases, marker fences, terminal tick planner and pure algorithms are retained with product adapters removed.

Canonical units are ayahs. Long ayahs use bounded internal spans of at most eight words (further bounded by configured lookahead), independent of font wrapping. Identity-backed complete internal spans can move the cursor during speech; only the last span can emit ayah completion. Candidate scoring uses actual greedy-emission spans so later ayahs in a continuous window cannot overwhelm the current ayah's CTC comparison. Partial target and span confusers use the containing ayah's generated neighborhood plus distinct sibling words.

Default policy retains the legacy CTC margin, word coverage, speech floors, and 400–2,000 ms endpoint gate. This is an adapted orchestrator, not a byte-for-byte port of the host app's UI line scheduling or its experimental continuous-authority rollout. The canonical continuous-index/alignment helpers remain available internally with synthetic tests; no experimental mode is selected by environment variables.

The balanced preset uses the retained endpoint policy. Conservative additionally requires full word coverage. Lenient uses a 200 ms endpoint floor; conservative requires two stable endpoint cycles plus full word coverage. Identity margins and the non-accusatory event contract are unchanged. These opt-in pacing presets are not calibrated error-rate claims. `maximumWindowSeconds` is clamped to 2–12 seconds; choose enough context for your intended recitation pace. Backtrack retains approximate token-timed audio context; it cannot undo a verified completion. No reciter audio is included.

## Data changes

Schema 2 replaces visual line endings with one ayah ending per record and regenerates the confuser graph for 6,236 ayahs. It adds verbatim Arabic and surah names so a host can display actual text without a second data source. The normalized words, canonical token IDs, and word-token ends remain equal to the earlier map for every ayah. The new map SHA-256 is `ede4fdba97391a631f59324f5836b5ad8cd0d36119837d9af13a2816cc704308`.

The source Arabic in `Tools/data/quran-uthmani.json` retains every original Arabic string; translations are excluded. Normalized matching data is not presented as Quran text. Tanzil's additional verbatim-only condition still needs explicit consideration before publishing that matching index; generating it does not by itself settle permission to redistribute it. Model export provenance also remains qualified in the notices. Local implementation and passing tests are not legal clearance for those assets.
