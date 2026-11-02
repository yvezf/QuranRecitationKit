# Publication verification — 2026-11-01

Publication passed maintainer review. Only this repository was pushed. The source application's checkouts stayed read-only.

## Published

- Repository: https://github.com/yvezf/QuranRecitationKit
- Model: https://github.com/yvezf/QuranRecitationKit/releases/tag/model-v1
- SDK: https://github.com/yvezf/QuranRecitationKit/releases/tag/v0.1.0
- Model release contains exactly the ONNX model and `model-manifest.json`; no reciter audio was uploaded.
- SDK release contains 15 assets: four CLI/C archives, four Node prebuild archives, four Python abi3 wheels, Apple XCFramework + checksum, and the four-platform NuGet.
- No npm, PyPI, NuGet or crates.io registry publication was performed.

Identity prerequisite passed: GitHub CLI 2.89.0, authenticated owner `yvezf`; local author `Yvezf`. Global Git name/email were unset and unchanged. The one Rust repository-owner constant was pinned in `60d81f6` after a successful rebuild and ONNX tests. The working tree was clean before repository creation; local SDK/runtime/build directories were confirmed ignored.

## Green native evidence

The complete [CI run](https://github.com/yvezf/QuranRecitationKit/actions/runs/41349967199) and [release build](https://github.com/yvezf/QuranRecitationKit/actions/runs/41349967173) passed on build-source commit `482db6c`. These are actual hosted execution, not the earlier cross-compilation claim.

| Target | CI | Release build |
|---|---|---|
| Linux x64, Ubuntu 22.04 | green | green |
| Windows x64, Server 2022 | green | green |
| Apple-silicon Mac, macOS 15 | green | green |
| Intel Mac, macOS 15 | green | green |
| Apple static archive / Swift | tests + Simulator example build green | archive + tests green |

Desktop jobs explicitly download the public model, verify its size/hash and enable real ONNX forward tests. CI also checks Node, Python and .NET native integration. This establishes model loading/inference and binding execution; it is not a recitation-accuracy benchmark. Actual microphone playback remained inconclusive in the earlier local test.

## Red conditions and fixes

1. GitHub intentionally failed macOS 14 jobs during its retirement brownout (retirement November 2, 2026). Supported `macos-15` arm64 and `macos-15-intel` replaced it. Primary notice: https://github.com/actions/runner-images/issues/13518.
2. PyPI has no Intel macOS ONNX Runtime 1.24.2 wheel. `tools/prepare_runtime.py` links the Intel slice of Microsoft's checksum-pinned 1.24.2 Apple static archive into a C-API shared library. No runtime/model source or weights are changed; the resulting runtime passed native inference on Intel CI. Other desktop targets use the official platform runtime. Native archives include build provenance.
3. The Rust action's comma-separated component input was quoted correctly so clippy is requested as intended.

Obsolete failed runs were retained as evidence and cancelled once superseded. No provider/version downgrade or relaxed recognition threshold was used.

## Public download and local recording

The SDK's own OS cache was cleared, then the source-built `qrk model fetch` downloaded the newly published asset and verified:

```text
size: 88307457
sha256: 822534428f1ed54eb802a9c43d4ecbabdfd8ba346b4d88d710414b0bbe7b4d69
```

Running the owner's local recording through the default downloaded model produced:

```json
{"type":"verse_match","surah":78,"ayah":1,"confidence":0.8014313316148379,"duration_seconds":5.4}
{"duration":5.6,"transcript":"عم يتساءلون","type":"summary","verses":[{"ayah":1,"confidence":0.8014313316148379,"duration_seconds":5.4,"surah":78}]}
```

The file stayed local; it was not added to Git, CI, or release assets.

## Apple archive and tag

The released CI-built `QRKFFI.xcframework.zip` is 123,381,589 bytes:

```text
8116b345ca0f1aca43b80430d02e4ccc49028e71c62848656248ac09a22e43ab
```

Its published checksum, downloaded archive and original CI artifact matched. Source metadata was pinned in `49a4bba`. The still-unpublished v0.1.0 tag was updated with an explicit lease from `60d81f6` to `49a4bba` before publishing the draft, so SwiftPM version resolution includes the checksum manifest. No branch history was force-pushed. The [tag release verification](https://github.com/yvezf/QuranRecitationKit/actions/runs/41351498077) passed and preserved the reviewed binary instead of overwriting it with a nondeterministic rebuild.

## Fresh public clone proof

Commands were run against a new directory, with no prebuilt Apple archive in the checkout:

```sh
fresh=$(mktemp -d /tmp/qrk-public-proof.XXXXXX)
git clone https://github.com/yvezf/QuranRecitationKit.git "$fresh"
cargo build --manifest-path "$fresh/core/Cargo.toml" --workspace --release
"$fresh/core/target/release/qrk" selftest
# Download qrk-darwin-arm64.zip from v0.1.0; verify every SHA256SUMS.json entry.
"$fresh/.release-proof/native/qrk" selftest
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build --package-path "$fresh/bindings/swift"
```

Actual tails:

```text
Finished `release` profile [optimized] target(s) in 33.62s
source CLI:   {"ayahs":6236,"ok":true,"surahs":114,"type":"selftest"}
packaged CLI: {"ayahs":6236,"ok":true,"surahs":114,"type":"selftest"}
All native archive file checksums verified.
Downloading binary artifact https://github.com/yvezf/QuranRecitationKit/releases/download/v0.1.0/QRKFFI.xcframework.zip
[23/25] Linking recite-cli
[24/25] Applying recite-cli
Build complete! (46.67s)
```

The public Swift build succeeded using the pinned release download, without rebuilding Rust or Microsoft ONNX Runtime for Swift. SDK archives were checked to exclude acoustic weights, reciter audio and generated Quran indices.

## Remaining limits

No general accuracy/Tajweed claim, physical-iPhone performance benchmark or optional CoreML/DirectML provider verification is made. The clean model-v2 candidate pipeline remains unexecuted and unpromoted. Model-v1 custom export/preprocessing rights remain qualified in THIRD_PARTY_NOTICES; public release and attribution do not constitute a license grant. Integrators retain host signing/notarization, microphone-permission and native runtime prerequisite responsibilities.

## Additional consumer regression and source-only patch

A real external `.package(url: ..., from: "0.1.0")` consumer exposed a bug that a full-checkout build did not: SwiftPM's tagged-manifest evaluation virtualized `#filePath` to `/Package.swift`, so the companion JSON path resolved incorrectly. No model or native inference issue was involved.

Fixed in source-only **v0.1.1**: both manifests inline the verified URL/checksum, use Context.packageDirectory for optional local artifacts, and the pinning tool keeps the generated manifest pins synchronized. A tagged bare-Git consumer regression passed locally and was added to CI. Published v0.1.0 binaries/weights are unchanged; v0.1.1 explicitly reuses the exact v0.1.0 archive. New SwiftPM clients should request 0.1.1 or later. No published tag was rewritten for this patch.

The public prebuilt CLI also matched 78:1 locally without ORT_DYLIB_PATH. The fresh Swift CLI matched the same recording using the public default model helper. Their final transcript was `عم يتساءلون`; the recording remained local.

## Final hosted and public-consumer evidence

The final code CI run at `1a2c591` is fully green on all four desktop platforms and the Swift job, including the hosted tagged-Git regression: https://github.com/yvezf/QuranRecitationKit/actions/runs/41353882204.

The first hosted regression compiled successfully but macOS killed it on launch (SIGKILL). The harness now builds, explicitly ad-hoc signs/verifies its generated test executable, then launches it separately. Hosted execution passed after that change. No host security policy, release archive, model weight or recognition policy was changed to address it.

The actual public GitHub consumer was also verified, not only the local bare-Git regression. Its dependency range began at 0.1.0 and resolved the corrected 0.1.1 source tag:

```text
Computed https://github.com/yvezf/QuranRecitationKit.git at 0.1.1
Working copy of https://github.com/yvezf/QuranRecitationKit.git resolved at 0.1.1
Fetched .../releases/download/v0.1.0/QRKFFI.xcframework.zip from cache
Build of product 'Smoke' complete! (6.37s)
SWIFTPM CONSUMER PASS: tagged dependency, verified model, native inference, 114 surahs
```

Source-only patch: https://github.com/yvezf/QuranRecitationKit/releases/tag/v0.1.1. Binary downloads remain the v0.1.0 release (marked Latest); Swift clients should use 0.1.1 or later. The NuGet was inspected after publication and contains exactly the four promised native RIDs. Final source scan: 156 tracked files at scan time, zero prohibited binaries/audio/generated Quran indices, translation fields, credentials or personal paths. No simulator remained booted; the shared Hear DerivedData directory was the only persistent Hear build directory.
