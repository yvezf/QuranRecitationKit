# QuranRecitationKit

Offline Quran recitation tracking that can be embedded in a macOS, Windows or Linux application—or used from any language through a local helper process. Supply the passage you expect and mono audio; receive word progress, ayah matches and gentle retry events.

**One Rust engine. C ABI. Swift, Node, Python and .NET bindings. Local WebSocket/stdio helper.** Implemented and locally tested on macOS arm64; Windows cross-compilation checked. Remote platform CI and public distribution await the publisher’s review. Nothing has been pushed or published by this implementation.

## Fastest integration: any language

Supply a verified model directory containing `fastconformer_full_mixed.onnx` and `model-manifest.json`, then run:

```sh
qrk serve --model /path/to/model --stdio
```

Write JSON lines to stdin:

```json
{"type":"start","target":{"surah":112},"format":"f32le","sample_rate":16000}
{"type":"audio","data":"BASE64_LITTLE_ENDIAN_FLOAT32_PCM"}
{"type":"stop"}
```

Stdout returns JSON events and a final summary. For WebSocket binary PCM, use `qrk serve --port 7877 --token YOUR_LOCAL_SECRET --model /path/to/model`. It binds 127.0.0.1 only. [Protocol and short JS/Python/C# clients](protocol/SIDECAR.md).

Release builds can embed the platform CPU ONNX Runtime in the helper and extract verified bytes into a user-local runtime cache. The local macOS helper was tested without `ORT_DYLIB_PATH`. Windows runtime prerequisites depend on the selected Microsoft build; see the model/runtime notes. No Python or Node interpreter is required to run the helper.

## Native Node

```js
const {Recognizer}=require('@quranrecitationkit/node');
const reciter=new Recognizer({modelDir:'/path/to/model'});
reciter.on('event',console.log);
await reciter.setExpected({surah:112});
await reciter.feed(new Float32Array(16000)); // replace silence with your own PCM
const summary=await reciter.stop();
```

The binding serializes native worker calls and applies backpressure. [Node details](bindings/node/README.md).

## Swift, Python and .NET

Swift (root SwiftPM package; iOS 16+, macOS 14+):

```swift
import QuranRecitationKit
let model = try ModelPack(directory: modelDirectoryURL)
let r = try await RecitationRecognizer(modelPack: model)
let reader = Task { for await event in r.events { print(event) } }
try await r.setExpected(.surah(112))
await r.feed(pcm16k) // [Float], mono 16 kHz
let summary = try await r.stop()
reader.cancel()
```

Python 3.9+:

```python
from quranrecitationkit import Recognizer
r = Recognizer('/path/to/model', on_event=print)
r.set_expected({'surah': 112})
events = r.feed(pcm16k)  # iterable of mono 16 kHz floats
summary = r.stop()
```

.NET (`netstandard2.0`):

```csharp
using QuranRecitationKit;
using var r = new RecitationRecognizer("/path/to/model");
r.Event += e => Console.WriteLine(e.GetRawText());
r.SetExpected(RecitationTarget.Surah(112));
var events = r.Feed(pcm16k); // float[], mono 16 kHz
var summary = r.Stop();
```

Details: [Swift](bindings/swift/README.md), [Python](bindings/python/README.md), [.NET](bindings/dotnet/README.md). Local Swift builds first run `python3 tools/build_xcframework.py`. A public one-dependency SwiftPM install requires the reviewed release archive’s exact URL/checksum to be pinned. Python wheels and the full four-platform NuGet are built by the release workflow; these are not claimed published.

## C/C++, Rust, desktop frameworks

`core/qrk-ffi/include/qrk.h` exposes handle creation, set_expected, feed, stop, reset, free, model fetch and version. Feed callbacks receive borrowed UTF-8 JSON; the summary string is explicitly freed. No product/UI framework is required.

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

Events: `word_progress`, `verse_match`, `needs_retry` (`inconclusive`, `off_target`, `noise`, `too_short`), `raw_transcript`, `state`. The [schema](protocol/events.schema.json) is shared across bindings. Completion of a selected word range is reported for that selected range, not as evidence that the whole ayah was read.

Confidence is an uncalibrated CTC margin, not a probability of correct recitation. This is expected-text tracking, not open-ended Quran search or Tajweed assessment. Provisional highlighting cannot authorize completion. Recite with a brief endpoint pause; noise, reverb and general-Arabic ASR spelling can lead to retries. Do not present a retry as an accusation.

## Model and text

The model is 88,307,457 bytes, SHA-256 `822534428f1ed54eb802a9c43d4ecbabdfd8ba346b4d88d710414b0bbe7b4d69`. No model weights or recitation audio are in Git. `qrk model fetch` becomes available after the publisher sets the **single Rust `REPOSITORY_OWNER` constant** and publishes the model-v1 asset; until then, provide a local model directory.

Only verbatim [Tanzil](https://tanzil.net) Arabic plus attribution is distributed. Normalized/tokenized indices are built in memory and may be cached on the user's machine. No generated normalized Quran index ships. NVIDIA's actual Unigram tokenizer is converted with a pinned script; tokenization was compared against SentencePiece on all 77,441 tested source words. Source commit and model release are distinguished in the [notices](THIRD_PARTY_NOTICES.md).

v1 export provenance remains qualified; the clean NVIDIA/NeMo v2 candidate pipeline is prepared and explicitly unvalidated. See [MODEL_CARD.md](MODEL_CARD.md) and [model/export](model/export/README.md). No model is promoted automatically.

## Build and verify

Rust stable is required. Linux capture needs ALSA development headers (`libasound2-dev`, `pkg-config`). The default runtime provider is CPU; CoreML and DirectML are optional feature paths.

```sh
cargo build --manifest-path core/Cargo.toml --workspace --release
cargo test --manifest-path core/Cargo.toml --workspace
cargo fmt --manifest-path core/Cargo.toml --all --check
cargo clippy --manifest-path core/Cargo.toml --workspace --all-targets -- -D warnings
npm --prefix bindings/node ci
npm --prefix bindings/node run build
npm --prefix bindings/node test
```

Set `ORT_DYLIB_PATH` to an ONNX Runtime 1.24-compatible library for development, or `QRK_EMBED_RUNTIME` at build time to embed it. Tests do not require audio or a model download. Set `QRK_MODEL_DIR` for a real local-model forward test and `QRK_PARITY_TOKEN_MAP` for comparison with a locally held prior index. Runtime corpus parity concerns words, token IDs and word boundaries; former app-specific visual line wraps are not engine units.

CLI commands: `qrk wav --surah N [--ayahs a-b] file.wav --json`, `qrk mic --surah N --json`, `qrk devices`, `qrk serve`, `qrk model fetch`, `qrk selftest`. WAV accepts PCM16/Float32 and resamples. Capture never changes the user's device selection unless a device is explicitly passed; it reports drops/errors. Microphone use requires OS permission.

Local verification and remaining qualifications: [Phase A report](docs/PHASE-A-VERIFICATION.md) and [Phase B report](docs/PHASE-B-VERIFICATION.md). Publishing steps: [release guide](docs/RELEASING.md). Platform CI and release workflows are prepared; remote execution cannot be claimed before publication. macOS Intel uses an available Intel runner rather than the retired macOS 13 label.

## License

Project code: MIT, Yousef Alabadi. Portions derive from yazinsai's Tilawa MIT source pin, distinct from its v0.2.0 model release. NVIDIA weights/tokenizer: CC BY 4.0. Tanzil Arabic: CC BY 3.0 with additional verbatim-only conditions. ONNX Runtime and compiled dependencies retain their own notices. Carry [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md), `third-party/`, and the corpus notice with redistribution.
