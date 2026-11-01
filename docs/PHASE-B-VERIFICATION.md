# Phase B verification — 2026-11-01

Completed locally on macOS arm64. The Swift reference milestone and Phase A are preserved in Git history. Phase A commit: `d2a2851`; Swift reference: `bf5fcd3`. This phase replaces the shipping Swift engine with a thin wrapper over the same Rust C ABI and adds Python/.NET. No remote, push, app changes or model upload.

## Delivered structure

```text
Package.swift                         root SwiftPM entry
core/                                 core / onnx / audio / ffi / cli workspace
bindings/
  swift/                              actor API, Apple audio adapter, XCFramework build/release metadata
  node/                               napi-rs native worker + EventEmitter + sidecar client
  python/                             PyO3 abi3 wheel (Python 3.9+) + returned events/callback
  dotnet/                             netstandard2.0 SafeHandle/PInvoke + RID-native packaging
corpus/                               verbatim Tanzil Arabic, attribution, scoped variants
model/                                metadata, tokenizer, conversion/parity, clean-v2 candidate pipeline
protocol/                             one event schema, stdio/WebSocket guide + short clients
examples/                             node-mic, python-wav, dotnet-console, swift-ios, electron-plugin
tests/                                synthetic fixtures, C/sidecar checks, dev-only oracle generator
third-party/                          Rust/standard-library/ONNX/Node/.NET notices
tools/                                build, notice collection and release packaging
.github/workflows/                    four-desktop CI, Apple build, draft release, manual model candidate
```

## Verification results

| Check | Result |
|---|---|
| Rust workspace | 23 tests passed; real ONNX forward and all 6,236-ayah local oracle comparisons enabled |
| Swift binding | 7 tests passed; includes independent scorer/aligner fixtures, corpus/preamble projection, model guard, native silence and optional owner PCM parity |
| Node binding | 4 tests passed with local model; strict clippy passed |
| Python binding | 3 tests passed with local model; abi3 macOS 14 arm64 wheel built; strict clippy passed |
| .NET | netstandard2.0 library + net8 console build; native silence and owner-clip checks passed |
| NuGet consumer | Local macOS-arm64 test package installed in a separate project; native asset resolution + embedded runtime + silence rejection passed without a runtime-path override |
| Apple archives | iOS arm64, Simulator arm64/x64, macOS arm64/x64 static libraries assembled into an XCFramework |
| iOS demo | Generic Simulator and generic device builds succeeded, code signing disabled, shared DerivedData only |
| Desktop archive | Packaged CLI selftest passed; executable permission preserved; no model in archive |
| Windows | Final workspace MSVC cross-check passed; execution on Windows remains unverified |
| Corpus/tokenizer | Phase A: 114/6,236, 77,441 words, zero tokenizer/oracle mismatches; same code retained |
| Quality checks | Rust format + strict workspace/Python/Node clippy; Python script compile; workflow YAML parsed |
| Notices | 329 Rust packages accounted for, zero unresolved entries after supplements; Node/.NET notices included |
| Packaging guard | Full NuGet packing correctly refuses missing Intel Mac/Windows/Linux native artifacts |

There are 37 passing automated tests across Rust/Swift/Node/Python in this local configuration. The .NET checks are separate executable integration checks, not counted as unit tests. No reciter recording is a test fixture. Optional tests skip honestly when their local model/oracle/owner-clip variables are unset.

Apple's runtime archive was downloaded from Microsoft's pinned 1.24.2 URL and verified against its published archive SHA. Extraction preserves framework symlinks. Native Node rebuilds replace the destination inode and apply a local ad-hoc signature on macOS; this prevents stale code-signature cache kills. This is not Developer ID signing or notarization.

The Apple static build emits an upstream ort-sys warning for the Intel Simulator compiler-runtime archive selection; both Simulator architectures linked successfully in the example. No iPhone installation or physical-device execution was performed for this extraction.

## Identical-audio comparison

The owner-owned recording was converted once to local mono PCM16 16 kHz, outside Git, and fed in identical 4,800-sample chunks. It contains **78:1**, not the Fatiha named in the original request. The same real-model event was produced:

```text
Rust CLI: verse_match 78:1 confidence=0.7940109345435182 duration_seconds=5.4
Node:     verse_match 78:1 confidence=0.7940109345435182 duration_seconds=5.4
Python:   verse_match 78:1 confidence=0.7940109345435182 duration_seconds=5.4
.NET:     verse_match 78:1 confidence=0.7940109345435182 duration_seconds=5.4
Swift:    verse_match 78:1 confidence=0.790055553599167  duration_seconds=5.4
all:      summary verses=1/1 duration=5.6 transcript=عم يتساءلون
```

Swift's direct-PCM test bypasses resampling. The confidence difference persists with Microsoft's Apple-static runtime versus the official desktop dynamic runtime; its exact numerical kernel cause has not been isolated. Acceptance, verse, duration and final transcript agree. Do not claim bit-identical acoustic outputs across native runtime distributions. Independent synthetic Swift/Rust scorer and aligner fixtures agree within 0.0001.

Phase A microphone capture remained zero-drop but recognition was inconclusive; this phase does not turn that into a successful live-recitation accuracy claim. The localhost sidecar start/audio/stop test passed in Phase A and the engine/protocol semantics were retained.

## API/readme refinements

README examples now match the actual Rust, Swift, Node, Python and C# APIs. The root Swift Package supports a single repository dependency once the reviewed binary URL/checksum is pinned. The single model owner/hash/size definition lives in Rust; Swift reads its compiled metadata. The Apple adapter bypasses resampling for already-16-kHz PCM, preserving every supplied sample. The SwiftUI demo displays the unnumbered basmala separately and provides the Tanzil link/full text notice.

The original BPE assumption was corrected to verified Unigram. The public corpus unit is an ayah/word range; former Garden line wraps and serialized product confusers stay out. A model facade owns I/O rather than making the pure core depend on ONNX. Static Apple linkage avoids extracting an unsigned runtime into an iOS application. Desktop helper distributions remain self-contained via embedded dynamic runtime bytes; this is not a claim that all Windows/Linux dependencies are static.

## Unverified / publication steps

- Actual Windows, Linux and Intel Mac runtime execution and remote CI: prepared, not run, because no push is authorized here. Optional CoreML/DirectML providers are untested.
- Four-platform NuGet aggregation, non-local wheels/prebuilds, npm/PyPI/NuGet publication and Developer ID signing/notarization: not performed. A local arm64-only NuGet was used solely to verify package consumption; it is not the promised universal release.
- Public SwiftPM binary URL/checksum and default model URL: deliberately unconfigured until the maintainer publishes the reviewed artifacts. No invented URL/checksum is treated as live. `docs/RELEASING.md` gives the exact pin command and warns against replacing an asset with different bytes.
- v1 custom export/preprocessing rights remain qualified in THIRD_PARTY_NOTICES; no public model was uploaded. The clean NVIDIA v2 candidate is prepared, unexecuted and unpromoted.
- No benchmark establishes universal live-recitation/Tajweed accuracy. The tested local file is one example.

## Repository boundaries and scans

The final staged tree is checked for prohibited audio/model/native artifacts, generated Quran indices, translation fields, private reciter manifests, personal paths, device identifiers and credentials. Expected license/documentation references to excluded material are not shipped data. Source app checkouts remained read-only. Only `/private/tmp/HearBuild-shared` persists as a Hear DerivedData directory; no simulator remains booted.

Elapsed extraction/build/verification time, excluding the earlier audit: approximately 1.6 hours. No publishing time is included.

Final source scan: 151 tracked files at scan time; zero prohibited artifacts, zero private/credential/translation hits, zero remotes. Runtime-index verification helper passed with the local oracle. `git diff --cached --check` is clean.
