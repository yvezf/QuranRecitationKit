# Publication verification — 2026-11-01

maintainer approved publication. Only this repository was pushed. The source application's checkouts stayed read-only.

## Published

- Repository: https://github.com/yvezfscarves-afk/QuranRecitationKit
- Model: https://github.com/yvezfscarves-afk/QuranRecitationKit/releases/tag/model-v1
- SDK: https://github.com/yvezfscarves-afk/QuranRecitationKit/releases/tag/v0.1.0
- Model release contains exactly the ONNX model and `model-manifest.json`; no reciter audio was uploaded.
- SDK release contains 15 assets: four CLI/C archives, four Node prebuild archives, four Python abi3 wheels, Apple XCFramework + checksum, and the four-platform NuGet.
- No npm, PyPI, NuGet or crates.io registry publication was performed.

Identity prerequisite passed: GitHub CLI 2.89.0, authenticated owner `yvezfscarves-afk`; local author `Yvezf`. Global Git name/email were unset and unchanged. The one Rust repository-owner constant was pinned in `60d81f6` after a successful rebuild and ONNX tests. The working tree was clean before repository creation; local SDK/runtime/build directories were confirmed ignored.

## Green native evidence

The complete [CI run](https://github.com/yvezfscarves-afk/QuranRecitationKit/actions/runs/41349967199) and [release build](https://github.com/yvezfscarves-afk/QuranRecitationKit/actions/runs/41349967173) passed on build-source commit `482db6c`. These are actual hosted execution, not the earlier cross-compilation claim.

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

Its published checksum, downloaded archive and original CI artifact matched. Source metadata was pinned in `49a4bba`. The still-unpublished v0.1.0 tag was updated with an explicit lease from `60d81f6` to `49a4bba` before publishing the draft, so SwiftPM version resolution includes the checksum manifest. No branch history was force-pushed. The [tag release verification](https://github.com/yvezfscarves-afk/QuranRecitationKit/actions/runs/41351498077) passed and preserved the reviewed binary instead of overwriting it with a nondeterministic rebuild.

## Fresh public clone proof

Commands were run against a new directory, with no prebuilt Apple archive in the checkout:

```sh
fresh=$(mktemp -d /tmp/qrk-public-proof.XXXXXX)
git clone https://github.com/yvezfscarves-afk/QuranRecitationKit.git "$fresh"
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
Downloading binary artifact https://github.com/yvezfscarves-afk/QuranRecitationKit/releases/download/v0.1.0/QRKFFI.xcframework.zip
[23/25] Linking recite-cli
[24/25] Applying recite-cli
Build complete! (46.67s)
```

The public Swift build succeeded using the pinned release download, without rebuilding Rust or Microsoft ONNX Runtime for Swift. SDK archives were checked to exclude acoustic weights, reciter audio and generated Quran indices.

## Remaining limits

No general accuracy/Tajweed claim, physical-iPhone performance benchmark or optional CoreML/DirectML provider verification is made. The clean model-v2 candidate pipeline remains unexecuted and unpromoted. Model-v1 custom export/preprocessing rights remain qualified in THIRD_PARTY_NOTICES; public release and attribution do not constitute a license grant. Integrators retain host signing/notarization, microphone-permission and native runtime prerequisite responsibilities.
