# QuranRecitationKit

[![Cross-platform CI](https://github.com/yvezf/QuranRecitationKit/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/yvezf/QuranRecitationKit/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/yvezf/QuranRecitationKit)](https://github.com/yvezf/QuranRecitationKit/releases/tag/v0.2.1)

Offline Quran recitation tracking for your app. Supply the passage you expect and mono audio; receive provisional word progress, ayah matches, transcripts and neutral retry events.

**One Rust engine. C ABI. Swift, Node, Python and .NET bindings. Local WebSocket/stdio helper.** Native CI passed on macOS arm64/x64, Windows x64 and Linux x64, including the public model download and actual ONNX inference. The iOS SwiftUI example also builds. [Releases](https://github.com/yvezf/QuranRecitationKit/releases/tag/v0.2.1) · [Model](https://github.com/yvezf/QuranRecitationKit/releases/tag/model-v2) · [Publication verification](docs/PUBLICATION-2026-11-01.md).

**Use 0.2.1 or later for continuous multi-ayah tracking.** This patch ports the Swift reference's anchored cursor, fresh-evidence and natural/following-word confirmation rules; it fixes the single-ayah-tail limitation in earlier versions. The clean NVIDIA model-v2 remains unchanged. [Continuous-session and package verification](docs/CONSUMER-FIXES-2026-11-01.md) · [model-v2 verification](docs/MODEL-V2-RELEASE-2026-11-01.md).

## Pick your door

| Host | Start here |
|---|---|
| Any desktop language, Electron, Qt, Tauri | Download a `qrk-<platform>.zip`, spawn `qrk serve --stdio`, exchange JSON/PCM |
| C / C++ | C library and `qrk.h` inside the platform archive; see [C ABI](core/qrk-ffi/include/qrk.h) |
| Swift / iOS / macOS | Add this repository as a SwiftPM dependency; [Swift guide](bindings/swift/README.md) |
| Node | Download the matching `node-<platform>.zip` into the source package; [Node guide](bindings/node/README.md) |
| Python 3.9+ | Install an attached platform wheel; [Python guide](bindings/python/README.md) |
| .NET | Use the attached four-platform `.nupkg` as a local feed; [.NET guide](bindings/dotnet/README.md) |

## Why this one

One native core, every platform, any language. Code is MIT; NVIDIA weights are CC BY 4.0; Tanzil text is CC BY 3.0 with its verbatim-text conditions. The default model-v2 is exported directly from NVIDIA using licensed NeMo/ONNX tooling; the historical v1 qualification remains documented. See [third-party notices](THIRD_PARTY_NOTICES.md#2-nvidia-acoustic-weights-vocabulary-and-tokenizer).

### How it compares (as of 2026-11-01)

This compares published integration paths and stated terms, rather than recognition accuracy. Platform listings are declarations unless a verification is linked. “Unverified” means the checked sources did not establish that claim.

| Project | Integrates from | Platforms | Code license | Model/data license |
|---|---|---|---|---|
| [QuranRecitationKit (this)](https://github.com/yvezf/QuranRecitationKit) | Any language via C ABI or `qrk` sidecar; Swift, Node, Python, .NET | macOS 14+, Windows x64, Linux x64, iOS 16+; [verification](docs/PUBLICATION-2026-11-01.md) | [MIT](LICENSE) | NVIDIA CC BY 4.0 weights; Tanzil CC BY 3.0 text with verbatim conditions; [direct NVIDIA/NeMo v2 export](MODEL_CARD.md) |
| [Tilawa](https://github.com/yazinsai/tilawa) | TypeScript: web, Node, React Native | Browser, Node, React Native | MIT | [Default Zipformer model/phoneme corpus: NPL-1.2](https://github.com/yazinsai/tilawa/blob/2f2617460dc4a6b967e0cc49fa04804bbf22ec69/NOTICE.md) (no paid features; share-alike); FastConformer path: NVIDIA CC BY 4.0 |
| [recite_quran](https://pub.dev/packages/recite_quran/versions/1.0.5) | Flutter/Dart package | Android, iOS, Linux, macOS, web, Windows, [per pub.dev](https://pub.dev/packages/recite_quran) | Custom [“Sacred Covenant”](https://pub.dev/packages/recite_quran/license); pub.dev labels it unknown | Referenced [Quran-Lab Zipformer-v3: NPL-1.2](https://huggingface.co/Quran-Lab/zipformer_p-arabic-v3); other bundled data terms unverified |
| [QuranRecognitionKit](https://github.com/akhandafm17/QuranRecognitionKit) | Swift package | iOS 17+, macOS 14+, [declared in manifest](https://github.com/akhandafm17/QuranRecognitionKit/blob/81b769ab52a054f773d1c0127f57315fdf02350c/Package.swift) | MIT | [NVIDIA FastConformer CC BY 4.0, per model notice](https://github.com/akhandafm17/QuranRecognitionKit/blob/81b769ab52a054f773d1c0127f57315fdf02350c/MODEL_NOTICE.md); bundled Qur'an text terms unverified |
| [Real-Time Quran recitation tracker](https://github.com/yayaiu6/Real-Time-Quran-recitation-tracker-System) | Python Flask/Socket.IO web app | Python server + browser client; specific OS support unverified | MIT | Recommended [fine-tuned NeMo Conformer: MIT, per model card](https://huggingface.co/MostafaAhmed98/Conformer-CTC-Arabic-ASR); bundled checkpoint/text provenance unverified; Groq Whisper is an alternative backend |
| [Tarteel](https://tarteel.ai) | App; [no public recognition API offered](https://support.tarteel.ai/en/articles/12414464-do-you-have-an-api-i-can-use) | iOS, Android; [Apple Silicon Mac through the iOS app](https://support.tarteel.ai/en/articles/12414477-can-i-use-tarteel-on-my-computer) | Proprietary [service/app terms](https://tarteel.ai/terms) | Redistributable recognition-model/data license unverified; published QUL resources are separate |

Tilawa is the ancestor of this engine's normalizer, decoder and aligner; see [THIRD_PARTY_NOTICES](THIRD_PARTY_NOTICES.md).

[Cell-by-cell sources and qualifications](docs/COMPARISON-2026-11-01.md).

**npm, PyPI and NuGet registry publication has not been performed.** Packages and native binaries are available as GitHub release assets. No registry account is needed to use those files. Rust crates are source/workspace dependencies, not claimed published to crates.io.

### Desktop downloads

| Platform | CLI + C library/header | Node prebuild |
|---|---|---|
| macOS Apple silicon, 14+ | [qrk-darwin-arm64.zip](https://github.com/yvezf/QuranRecitationKit/releases/download/v0.2.1/qrk-darwin-arm64.zip) | [node-darwin-arm64.zip](https://github.com/yvezf/QuranRecitationKit/releases/download/v0.2.1/node-darwin-arm64.zip) |
| macOS Intel, 14+ | [qrk-darwin-x64.zip](https://github.com/yvezf/QuranRecitationKit/releases/download/v0.2.1/qrk-darwin-x64.zip) | [node-darwin-x64.zip](https://github.com/yvezf/QuranRecitationKit/releases/download/v0.2.1/node-darwin-x64.zip) |
| Windows x64 | [qrk-win32-x64.zip](https://github.com/yvezf/QuranRecitationKit/releases/download/v0.2.1/qrk-win32-x64.zip) | [node-win32-x64.zip](https://github.com/yvezf/QuranRecitationKit/releases/download/v0.2.1/node-win32-x64.zip) |
| Linux x64, glibc 2.34+ | [qrk-linux-x64.zip](https://github.com/yvezf/QuranRecitationKit/releases/download/v0.2.1/qrk-linux-x64.zip) | [node-linux-x64.zip](https://github.com/yvezf/QuranRecitationKit/releases/download/v0.2.1/node-linux-x64.zip) |

The Linux CLI needs ALSA runtime libraries. Windows may need Microsoft's current VC++ Redistributable. Desktop helpers embed the platform CPU ONNX Runtime and extract hash-verified runtime bytes into a user-local cache. No Node or Python interpreter is required for the helper. Host applications own signing/notarization and microphone permissions.

### macOS browser downloads and Gatekeeper

Desktop binaries are **not Developer-ID signed or notarized**. Any ad-hoc build signature does not establish an identified developer. After verifying the release source and checksums, a browser-downloaded archive may require removing quarantine from these specific extracted files:

```sh
xattr -d com.apple.quarantine qrk libqrk.dylib
```

On older macOS, Finder → right-click/Control-click `qrk` → Open may offer the per-file exception. **macOS 15+ removed that override** for incorrectly signed/unnotarized software; after the initial blocked launch, use System Settings → Privacy & Security → Open Anyway. [Apple's macOS Sequoia guidance](https://developer.apple.com/news/?id=saqachfa). No global Gatekeeper changes are required or recommended.

Developer-ID signing and notarization remain a release follow-up. They require the owner's signing certificate/private key and password as repository secrets, plus notary credentials and a reviewed signing workflow. This release does not claim notarization.

## Start with the sidecar: any language

Extract the platform ZIP, then:

```sh
./qrk model fetch
./qrk selftest
./qrk serve --stdio
```

On Windows use `.\qrk.exe`. The model-fetch command downloads the separate, hash-pinned model; recognition then works offline. A manual model directory can be supplied with `--model /path/to/model`.

Write JSON lines to stdin:

```json
{"type":"start","target":{"surah":112},"format":"f32le","sample_rate":16000}
{"type":"audio","data":"BASE64_LITTLE_ENDIAN_FLOAT32_PCM"}
{"type":"stop"}
```

Stdout returns JSON events and a final summary. For WebSocket binary PCM, run `qrk serve --port 7877 --token YOUR_LOCAL_SECRET`; it binds to the loopback address 127.0.0.1. [Protocol and short JS/Python/C# clients](protocol/SIDECAR.md).

Other commands: `qrk wav --surah 112 my-reading.wav --json`, `qrk mic --surah 112 --json`, `qrk devices`. WAV accepts PCM16/Float32 and resamples. Capture is explicit and subject to OS permission; drops/errors are reported.

## Native Node

Clone the repository, extract the matching `node-<platform>.zip` into `bindings/node` (its contents start with `prebuilds/`), then run `npm install /path/to/QuranRecitationKit/bindings/node` in your host project. This installs a **local package**, not an npm-published release. The facade needs its `ws` dependency; no Rust build is needed when the matching prebuild exists.

```js
const {Recognizer}=require('@quranrecitationkit/node');
const reciter=new Recognizer({modelDir:'/path/printed/by/qrk-model-fetch'});
reciter.on('event',console.log);
await reciter.setExpected({surah:112});
await reciter.feed(new Float32Array(16000)); // replace silence with your PCM
const summary=await reciter.stop();
```

The binding serializes native worker calls and applies backpressure. [Node details](bindings/node/README.md).

## Swift, Python and .NET

Swift 5.9+, iOS 16+, macOS 14+. Add the public repository to your package dependencies:

```swift
.package(url: "https://github.com/yvezf/QuranRecitationKit.git", from: "0.2.1")
```

Choose `QuranRecitationKit` and optionally `QuranRecitationAudio`. SwiftPM downloads the exact checksum-pinned Apple archive. No local Rust toolchain is required for this path.

```swift
import QuranRecitationKit
let model = try await ModelPack.download() // explicit one-time verified download
let r = try await RecitationRecognizer(modelPack: model)
let reader = Task { for await event in r.events { print(event) } }
try await r.setExpected(.surah(112))
await r.feed(pcm16k) // [Float], mono 16 kHz
let summary = try await r.stop()
reader.cancel()
```

Python: download the wheel for your platform from [v0.2.1](https://github.com/yvezf/QuranRecitationKit/releases/tag/v0.2.1), then `python -m pip install /path/to/downloaded.whl`. These are Python 3.9+ abi3 wheels, not a PyPI upload.

```python
from quranrecitationkit import Recognizer, model_fetch
r = Recognizer(model_fetch(), on_event=print)
r.set_expected({'surah': 112})
events = r.feed(pcm16k)  # iterable of mono 16 kHz floats
summary = r.stop()
```

.NET: download [QuranRecitationKit.0.2.1.nupkg](https://github.com/yvezf/QuranRecitationKit/releases/download/v0.2.1/QuranRecitationKit.0.2.1.nupkg). Add the package reference without restoring, then restore using both the local folder and NuGet.org for Microsoft's dependencies:

```sh
dotnet add package QuranRecitationKit --version 0.2.1 --no-restore
dotnet restore --source /folder/containing/the/nupkg --source https://api.nuget.org/v3/index.json
```

The netstandard2.0 package includes all four desktop native RIDs. It has not been published to the NuGet registry.

```csharp
using QuranRecitationKit;
using var r = new RecitationRecognizer(ModelPack.Fetch());
r.Event += e => Console.WriteLine(e.GetRawText());
r.SetExpected(RecitationTarget.Surah(112));
var events = r.Feed(pcm16k); // float[], mono 16 kHz
var summary = r.Stop();
```

Details: [Swift](bindings/swift/README.md), [Python](bindings/python/README.md), [.NET](bindings/dotnet/README.md).

## C/C++, Rust, desktop frameworks

The [C header](core/qrk-ffi/include/qrk.h) exposes handle creation, set_expected, feed, stop, reset, free, model fetch and version. Feed callbacks receive borrowed UTF-8 JSON; the summary string is explicitly freed. Windows applications can resolve the exported C functions from `qrk.dll`; C ABI calls must obey the header's lifetime rules.

Rust's pure core is `qrk-core`; the I/O/model facade is `qrk-onnx::Recognizer`:

```rust,ignore
let corpus=qrk_onnx::load_corpus(None)?;
let model=qrk_onnx::ModelPack::from_directory(model_directory)?;
let mut reciter=qrk_onnx::Recognizer::new(model,corpus,qrk_core::Config::default())?;
reciter.set_expected(qrk_core::Target::Surah(112))?;
let events=reciter.feed(&pcm16k);
let summary=reciter.stop()?;
```

The core's generic recognizer permits a stub acoustic model for deterministic tests. The facade keeps ONNX/file/network dependencies out of the pure engine.

## Targets and events

- Whole surah: `{"surah":112}`.
- Inclusive ayah range: `{"surah":2,"from":255,"to":257}`.
- Half-open, zero-based word range: `{"surah":1,"ayah":7,"from":4,"to":9}`.

Events: `word_progress`, `verse_match`, `needs_retry` (`inconclusive`, `off_target`, `noise`, `too_short`), `raw_transcript`, `state`. The [schema](protocol/events.schema.json) is shared across bindings. A selected word-range match covers that selected range, not the whole ayah.

Match confidence is the uncalibrated CTC margin mapped to `1 - exp(-max(0, margin))`, not a probability of correct recitation. Raw-transcript confidence is the geometric mean of emitted-token peak posteriors; it does not authorize a verse match. This is expected-text tracking, not open-ended Quran search or Tajweed assessment. Provisional highlighting cannot authorize completion. Noise/reverb and general-Arabic ASR spelling can produce retries; do not present a retry as an accusation.

## Model and text

[Model v2](https://github.com/yvezf/QuranRecitationKit/releases/tag/model-v2): 88,880,384 bytes, SHA-256 `8771deacfa0d7cacc0116d5c4a27222dcfcf52a96e555a7e9d26ab265c7c8f09`. `qrk model fetch`, Python/.NET model-fetch helpers and Swift `ModelPack.download()` use the configured public release and verify its exact size/hash. No acoustic weights or recitation audio are in Git or SDK archives.

Distributed Arabic text is verbatim [Tanzil](https://tanzil.net), with attribution. Normalized/tokenized indices are built in memory and may be cached on the user's machine. NVIDIA's Unigram tokenizer conversion was compared against SentencePiece on all 77,441 source words. Source commit and model release are distinguished in the [notices](THIRD_PARTY_NOTICES.md).

Model-v2 uses the directly pinned NVIDIA checkpoint and licensed NeMo preprocessing, without Cyberistic's exporter or graph. Source fidelity, public acceptance/retry checks on four desktop platforms, and the local owned-recording checks passed. The older model-v1 remains available as previous; its provenance qualification is preserved. See [MODEL_CARD.md](MODEL_CARD.md) and the [export status](model/export/STATUS-2026-11-01.md).

## Build and verify

Rust stable is required. Linux capture builds need `libasound2-dev` and `pkg-config`. CPU is the tested provider; optional CoreML/DirectML paths remain unverified.

```sh
cargo build --manifest-path core/Cargo.toml --workspace --release
cargo test --manifest-path core/Cargo.toml --workspace
cargo fmt --manifest-path core/Cargo.toml --all --check
cargo clippy --manifest-path core/Cargo.toml --workspace --all-targets -- -D warnings
npm --prefix bindings/node ci
npm --prefix bindings/node run build
npm --prefix bindings/node test
```

For source-built inference, set `ORT_DYLIB_PATH` to an ONNX Runtime 1.24-compatible native library, or `QRK_EMBED_RUNTIME` when building to embed it. `tools/prepare_runtime.py` prepares the pinned runtime in CI, including Intel Mac linkage from Microsoft's static archive. To rebuild the Apple native archive rather than use the published one, run `python3 tools/build_xcframework.py`.

Tests need no audio. Set `QRK_MODEL_DIR` for native inference tests and `QRK_PARITY_TOKEN_MAP` for a local prior-index comparison. CI downloads and verifies the pinned default model explicitly and enables the model tests; generated matching indices remain user-local. [Publication verification](docs/PUBLICATION-2026-11-01.md) includes fresh-clone commands and actual CI links. [Phase A](docs/PHASE-A-VERIFICATION.md) and [Phase B](docs/PHASE-B-VERIFICATION.md) are historical extraction reports; their pre-publication qualifications are superseded where the publication report provides new evidence. [Maintainer release guide](docs/RELEASING.md).

## License

Project code: MIT, Yousef Alabadi. Portions derive from yazinsai's Tilawa MIT source commit `ec5cdc72c1c48ba29866ca2e3197d6b9a0e2e793`; later upstream model terms are separate. NVIDIA weights/tokenizer: CC BY 4.0. Tanzil Arabic: CC BY 3.0 with additional verbatim-text conditions. Runtime and binding dependencies retain their notices. Carry [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md), `third-party/`, and the corpus notice with redistribution.
