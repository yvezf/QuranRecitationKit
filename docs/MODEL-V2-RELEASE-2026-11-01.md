# Model-v2 and SDK 0.2.0 publication — 2026-11-01

Published: [repository](https://github.com/yvezf/QuranRecitationKit), [model-v2](https://github.com/yvezf/QuranRecitationKit/releases/tag/model-v2), [SDK v0.2.0](https://github.com/yvezf/QuranRecitationKit/releases/tag/v0.2.0).

## Result

The clean export is now the default. The old 2/12 number compared raw token strings on tones, not twelve recitations. The replacement fixes an actual ARM static-int8 crash and a preprocessing precision defect. The source-fidelity tolerance, recognizer acceptance thresholds, expected text and retry policy were not loosened. Raw decoder differences remain visible in the [validation report](https://github.com/yvezf/QuranRecitationKit/releases/download/model-v2/validation-report.json).

| Verification | Result |
|---|---|
| Direct NVIDIA/NeMo source fidelity | 16/16, original 0.005 tolerance; worst log-probability error 0.000187874 |
| Public non-speech rejection/retry behavior | 15/15 on each of Linux, Windows, Apple Silicon Mac and Intel Mac (60 checks) |
| Local owned recording | 14/14: nine gain/chunk combinations accept 78:1; four wrong targets and a 100 ms truncation reject |
| Fresh public source clone | `cargo build --release --locked`, `qrk selftest` and explicit 78:1 WAV target pass |
| Packaged Apple Silicon CLI / Node / Python / .NET native library | All accept 78:1; Node/Python/CLI report version 0.2.0 |
| Public SwiftPM, exact version 0.2.0 | Fresh package/cache resolves, checks the v2 model pin, loads 114 surahs and accepts 78:1 through the published archive |
| SDK CI | Linux x64, Windows x64, macOS arm64/x64, Swift tests, iOS example build and tagged SwiftPM dependency check pass |
| Release builders | All platform packages and Apple archive pass; 15 SDK release assets |
| Repository hygiene | No model/checkpoint/reciter audio/PCM/embeddings, private paths/email or backend endpoints committed; MIT detected; authors map to yvezf |

Exact raw tone-token compatibility is still 6/12; retry-subtype equality is 13/15 per platform. Two tones change from `off_target` to `noise`; both reject. Those diagnostics were not relabeled as exact matches. See [method, defects and historical failure](../model/export/STATUS-2026-11-01.md).

## Reproducible identities

- Export source: `55df545f938d0454eeaae2f29b625056d746311d`.
- SDK implementation: `bbe8bffcddd3278639fabf6feeda3f961246680c`.
- Final SDK tag/checksum pin: `f0b00237cf94f190a4c50df11dfb991f87312d56`.
- Model: 88,880,384 bytes, SHA-256 `8771deacfa0d7cacc0116d5c4a27222dcfcf52a96e555a7e9d26ab265c7c8f09`.
- Apple archive: SHA-256 `3b80a00f6f1fdb0148e1a8bfbd774ffb26a95e1e202d58d59e182787f933b90c`; the downloaded artifact, release API digest and both Swift manifests agree. Archive bytes were not replaced after pinning.
- Model cache: versioned `model-v2`; older model-v1 caches are preserved. Swift/.NET derive manifest/cache metadata from the native core.

[Model export/native gate](https://github.com/yvezf/QuranRecitationKit/actions/runs/41363708288), [implementation CI](https://github.com/yvezf/QuranRecitationKit/actions/runs/41365167647), [final pin CI, attempt 2](https://github.com/yvezf/QuranRecitationKit/actions/runs/41366058582/attempts/2), [release builders](https://github.com/yvezf/QuranRecitationKit/actions/runs/41365169300).

The pin CI was initially cancelled while its new public archive URL was not yet available. It was rerun after publication and passed; the separate fresh public SwiftPM consumer also passed. The unpublished SDK tag was moved to its checksum-pin commit with the release workflow temporarily disabled/re-enabled, preserving the reviewed archive bytes. Published assets were then checked against their GitHub digests.

## Consumer proof

A fresh public clone built in 36.05 seconds, then returned:

```text
qrk 0.2.0
{"ayahs":6236,"ok":true,"surahs":114,"type":"selftest"}
verse_match 78:1
```

The WAV command uses the clip's actual target, rather than asking a one-ayah clip to complete the whole surah:

```sh
qrk wav --surah 78 --ayahs 1-1 "$OWNED_WAV" --json
```

A fresh SwiftPM consumer used a new local package/cache and the public dependency:

```swift
.package(url: "https://github.com/yvezf/QuranRecitationKit.git", exact: "0.2.0")
```

It returned:

```text
PUBLIC TAGGED SWIFTPM 0.2.0 PASS: 114 surahs; v2 model pin; verse_match 78:1
```

Private recording files remained local. Temporary consumer checkouts, resampled audio and build output were removed after verification. Only counts and verse identifiers are reported publicly. About 1.93 GiB of intermediate export graphs was removed; receipts and verified release bytes were retained locally.

## Provenance, previous versions and limits

Model-v2 is reproduced directly from the pinned NVIDIA checkpoint through licensed NeMo/ONNX tooling. It does not use Cyberistic's custom exporter or graph. NVIDIA CC BY 4.0 attribution, export modifications and full tool notices accompany the separate model release. Tilawa's MIT algorithm ancestry and Tanzil's verbatim-text conditions remain documented. [License/contract](../MODEL_CARD.md), [third-party notices](../THIRD_PARTY_NOTICES.md), [comparison sources](COMPARISON-2026-11-01.md).

Previous releases remain published and unchanged in asset count: v0.1.0 (15), v0.1.1 (0), model-v1 (2). New releases: model-v2 (5), v0.2.0 (15). Model-v1 is labeled previous and keeps its historical export-rights qualification.

These fixtures and variations of one owned recording are not a multi-reciter accuracy benchmark or Tajweed assessment. Native desktop CPU inference is tested; the iOS example builds, but specific-iPhone runtime performance is not measured. No npm, PyPI or NuGet registry publication was performed; GitHub assets/local feeds are the documented installation path. Hear repositories were not edited, committed or pushed.
