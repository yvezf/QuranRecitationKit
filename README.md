# QuranRecitationKit

[![Cross-platform CI](https://github.com/yvezfscarves-afk/QuranRecitationKit/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/yvezfscarves-afk/QuranRecitationKit/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/yvezfscarves-afk/QuranRecitationKit)](https://github.com/yvezfscarves-afk/QuranRecitationKit/releases/tag/v0.1.0)

Offline Quran recitation tracking for your app. Supply the passage you expect and mono audio; receive provisional word progress, ayah matches, transcripts and neutral retry events.

**One Rust engine. C ABI. Swift, Node, Python and .NET bindings. Local WebSocket/stdio helper.** Native CI passed on macOS arm64/x64, Windows x64 and Linux x64, including the public model download and actual ONNX inference. The iOS SwiftUI example also builds. [Releases](https://github.com/yvezfscarves-afk/QuranRecitationKit/releases/tag/v0.1.0) · [Model](https://github.com/yvezfscarves-afk/QuranRecitationKit/releases/tag/model-v1) · [Publication verification](docs/PUBLICATION-2026-11-01.md).

SwiftPM consumers should use **0.1.1 or later**. This source-only patch fixes tagged manifest resolution and reuses the checksum-verified v0.1.0 native archive; other platform artifacts remain v0.1.0. [SwiftPM patch release](https://github.com/yvezfscarves-afk/QuranRecitationKit/releases/tag/v0.1.1).

## Pick your door

| Host | Start here |
|---|---|
| Any desktop language, Electron, Qt, Tauri | Download a `qrk-<platform>.zip`, spawn `qrk serve --stdio`, exchange JSON/PCM |
| C / C++ | C library and `qrk.h` inside the platform archive; see [C ABI](core/qrk-ffi/include/qrk.h) |
| Swift / iOS / macOS | Add this repository as a SwiftPM dependency; [Swift guide](bindings/swift/README.md) |
| Node | Download the matching `node-<platform>.zip` into the source package; [Node guide](bindings/node/README.md) |
| Python 3.9+ | Install an attached platform wheel; [Python guide](bindings/python/README.md) |
| .NET | Use the attached four-platform `.nupkg` as a local feed; [.NET guide](bindings/dotnet/README.md) |

**npm, PyPI and NuGet registry publication has not been performed.** Packages and native binaries are available as GitHub release assets. No registry account is needed to use those files. Rust crates are source/workspace dependencies, not claimed published to crates.io.

### Desktop downloads

| Platform | CLI + C library/header | Node prebuild |
|---|---|---|
| macOS Apple silicon, 14+ | [qrk-darwin-arm64.zip](https://github.com/yvezfscarves-afk/QuranRecitationKit/releases/download/v0.1.0/qrk-darwin-arm64.zip) | [node-darwin-arm64.zip](https://github.com/yvezfscarves-afk/QuranRecitationKit/releases/download/v0.1.0/node-darwin-arm64.zip) |
| macOS Intel, 14+ | [qrk-darwin-x64.zip](https://github.com/yvezfscarves-afk/QuranRecitationKit/releases/download/v0.1.0/qrk-darwin-x64.zip) | [node-darwin-x64.zip](https://github.com/yvezfscarves-afk/QuranRecitationKit/releases/download/v0.1.0/node-darwin-x64.zip) |
| Windows x64 | [qrk-win32-x64.zip](https://github.com/yvezfscarves-afk/QuranRecitationKit/releases/download/v0.1.0/qrk-win32-x64.zip) | [node-win32-x64.zip](https://github.com/yvezfscarves-afk/QuranRecitationKit/releases/download/v0.1.0/node-win32-x64.zip) |
| Linux x64, glibc 2.34+ | [qrk-linux-x64.zip](https://github.com/yvezfscarves-afk/QuranRecitationKit/releases/download/v0.1.0/qrk-linux-x64.zip) | [node-linux-x64.zip](https://github.com/yvezfscarves-afk/QuranRecitationKit/releases/download/v0.1.0/node-linux-x64.zip) |

The Linux CLI needs ALSA runtime libraries. Windows may need Microsoft's current VC++ Redistributable. Desktop helpers embed the platform CPU ONNX Runtime and extract hash-verified runtime bytes into a user-local cache. No Node or Python interpreter is required for the helper. Host applications own signing/notarization and microphone permissions.

## Fastest integration: any language

Extract the platform ZIP, then:

```sh
./qrk model fetch
./qrk selftest
./qrk serve --stdio
```

On Windows use `.\qrk.exe`. The first command downloads the separate, hash-pinned model; recognition then works offline. A manual model directory can be supplied with `--model /path/to/model`.

Write JSON lines to stdin:

```json
{"type":"start","target":{"surah":112},"format":"f32le","sample_rate":16000}
{"type":"audio","data":"BASE64_LITTLE_ENDIAN_FLOAT32_PCM"}
{"type":"stop"}
```

Stdout returns JSON events and a final summary. For WebSocket binary PCM, run `qrk serve --port 7877 --token YOUR_LOCAL_SECRET`; it binds 127.0.0.1 only. [Protocol and short JS/Python/C# clients](protocol/SIDECAR.md).

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
.package(url: "https://github.com/yvezfscarves-afk/QuranRecitationKit.git", from: "0.1.1")
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

Python: download the wheel for your platform from [v0.1.0](https://github.com/yvezfscarves-afk/QuranRecitationKit/releases/tag/v0.1.0), then `python -m pip install /path/to/downloaded.whl`. These are Python 3.9+ abi3 wheels, not a PyPI upload.

```python
from quranrecitationkit import Recognizer, model_fetch
r = Recognizer(model_fetch(), on_event=print)
r.set_expected({'surah': 112})
events = r.feed(pcm16k)  # iterable of mono 16 kHz floats
summary = r.stop()
```

.NET: download [QuranRecitationKit.0.1.0.nupkg](https://github.com/yvezfscarves-afk/QuranRecitationKit/releases/download/v0.1.0/QuranRecitationKit.0.1.0.nupkg). Add the package reference without restoring, then restore using both the local folder and NuGet.org for Microsoft's dependencies:

```sh
dotnet add package QuranRecitationKit --version 0.1.0 --no-restore
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

Confidence is an uncalibrated CTC margin, not a probability of correct recitation. This is expected-text tracking, not open-ended Quran search or Tajweed assessment. Provisional highlighting cannot authorize completion. Noise/reverb and general-Arabic ASR spelling can produce retries; do not present a retry as an accusation.

## Model and text

[Model v1](https://github.com/yvezfscarves-afk/QuranRecitationKit/releases/tag/model-v1): 88,307,457 bytes, SHA-256 `822534428f1ed54eb802a9c43d4ecbabdfd8ba346b4d88d710414b0bbe7b4d69`. `qrk model fetch`, Python/.NET model-fetch helpers and Swift `ModelPack.download()` use the configured public release and verify its exact size/hash. No acoustic weights or recitation audio are in Git or SDK archives.

Only verbatim [Tanzil](https://tanzil.net) Arabic plus attribution is distributed. Normalized/tokenized indices are built in memory and may be cached on the user's machine. NVIDIA's Unigram tokenizer conversion was compared against SentencePiece on all 77,441 source words. Source commit and model release are distinguished in the [notices](THIRD_PARTY_NOTICES.md).

V1 export/preprocessing provenance remains qualified; attribution does not resolve missing permission. The clean NVIDIA/NeMo v2 candidate pipeline is prepared but unvalidated and unpromoted. See [MODEL_CARD.md](MODEL_CARD.md) and [model/export](model/export/README.md).

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

Tests need no audio. Set `QRK_MODEL_DIR` for native inference tests and `QRK_PARITY_TOKEN_MAP` for a local prior-index comparison. CI downloads and verifies model-v1 explicitly and enables the model tests; generated matching indices remain user-local. [Publication verification](docs/PUBLICATION-2026-11-01.md) includes fresh-clone commands and actual CI links. [Phase A](docs/PHASE-A-VERIFICATION.md) and [Phase B](docs/PHASE-B-VERIFICATION.md) are historical extraction reports; their pre-publication qualifications are superseded only where the publication report provides new evidence. [Maintainer release guide](docs/RELEASING.md).

## License

Project code: MIT, Yousef Alabadi. Portions derive from yazinsai's Tilawa MIT source pin, distinct from its v0.2.0 model release. NVIDIA weights/tokenizer: CC BY 4.0. Tanzil Arabic: CC BY 3.0 with additional verbatim-only conditions. Runtime and binding dependencies retain their notices. Carry [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md), `third-party/`, and the corpus notice with redistribution.
