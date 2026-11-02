# Continuous tracking and consumer fixes — SDK 0.2.1

[SDK release](https://github.com/yvezf/QuranRecitationKit/releases/tag/v0.2.1) · [implementation CI](https://github.com/yvezf/QuranRecitationKit/actions/runs/41370824451) · [final pin CI](https://github.com/yvezf/QuranRecitationKit/actions/runs/41372103546) · [release builders](https://github.com/yvezf/QuranRecitationKit/actions/runs/41370825509).

The independent consumer audit reproduced a real defect: word highlighting reached the end of the first ayah, but acceptance scored the final audio tail, the cursor did not advance, and a continuing recitation could erase the earlier match. The previous single-ayah and silence checks did not cover that contract. They were insufficient evidence for continuous tracking.

This patch fixes the engine and adds streaming regressions. SDK 0.2.0 was already public, so the new SDK is **0.2.1**. Previously published SDK/model assets were not replaced. The independently completed clean NVIDIA **model-v2 stays unchanged**; this fix also passes with historical model-v1.

## Acceptance semantics

`core/qrk-core/src/continuous.rs` ports the Swift continuous-session reference's anchored lexical alignment and confirmation rules; `session.rs` applies them to canonical ayahs, without product display-line plans:

- The verified cursor anchors matching. At most two decoded insertions are allowed; an expected-word deletion ends that alignment. Backtrack/lookahead stay bounded, and equivalent repeated occurrences prefer the recent verified anchor.
- Lexical floors remain 0.70 / 0.88, with the reference's combined-length edit-similarity definition. Evidence counts only when both capture and voiced frontiers advance by at least 3,200 samples; replaying one inference window cannot create fresh support.
- Adequate acoustic support, stable evidence and either a 300 ms natural pause, strong following-word evidence, or the reference's complete-breath/end-of-surah rule confirm words. Silence alone cannot authorize a match.
- CTC current-target identity remains an independent gate. The 0.035 target-versus-confuser margin and existing captured-speech floors were not lowered. Canonical continuation can support an already identified current ayah; it cannot rescue a failed current identity.
- Accepting an ayah advances a monotone audio fence. Later ayahs use their own retained segments, including at `stop()`, instead of re-scoring only the last tail. Large feeds are processed at capture-sized intervals before the rolling window trims evidence.
- Muqattaat keep their separate exact canonical-suffix and acoustic policy.

Why these changes: preserve the reference's verified progression while fixing when and where evidence is evaluated; do not loosen wrong-target acceptance to make a recording pass.

## Owned two-ayah recording gate

The same 10.798-second local recording was tested against both model-v1 and default model-v2. No audio, resampled PCM, raw transcript or speaker identity is distributed. Times below are consumed input-audio seconds, not inference latency:

```text
target 78:1–2, live:
  feed  5.700s  verse_match 78:1
  feed  7.500s  word_progress 78:2, word 0
  feed 10.798s  verse_match 78:2

target 78:1–1, same continuing recording:
  feed  5.700s  verse_match 78:1
  stop          verses=[78:1]; no credit for 78:2

target 78:1–2, terminal-only:
  stop 10.798s  verse_match 78:1
  stop 10.798s  verse_match 78:2

wrong target, surah 1:
  verses=[]; needs_retry off_target
```

Whole-surah 78 also advances through ayahs 1 and 2. This short clip does not complete the remaining ayahs. The recording-free [event receipt](verification/continuous-0.2.1.md) includes both model versions and the actual progress/match/retry events.

The primary fixture regression is `session::continuous_fixture_tests::continuous_two_ayah_fixture_advances_before_stop`, driven by `tests/fixtures/two-ayah-stream.json`. Further regressions cover a selected ayah followed by continuing speech, terminal per-ayah recovery, strict wrong-target rejection, a long ayah across rolling-window trims, four continuous ayahs, repeated identical ayahs, expected deletions and replayed evidence. The old constant stub that returned future words before their audio arrived was replaced by a time-aligned synthetic stream; its original assertion is retained and strengthened. No licensed audio is needed for these tests.

## Consumer and CLI checks

- Local Rust workspace: **37 tests pass**, including 29 pure-core tests; formatting and Clippy with warnings denied pass. A fresh public source clone at implementation commit `57e3a0ce4dce748ca21dfcbbd61dd2b400fa1095` builds, runs the workspace tests and passes `qrk selftest`; the temporary checkout/build is removed.
- The new Apple archive and a fresh public SwiftPM consumer at exact version **0.2.1** both accept 78:1 and 78:2. The consumer uses a fresh package/cache, the published checksum-pinned ZIP, and the default model-v2. Downloaded Apple-silicon CLI, stdio sidecar, Node prebuild, Python wheel and aggregate NuGet managed/native libraries also accept both ayahs. Private temporary PCM, consumers and build directories are removed after each check.
- CLI subcommands now describe themselves. A non-TTY model fetch emits decile progress, at most eleven lines, with no carriage-return flood. CI checks the real download path.
- A no-input-device CLI probe exits nonzero with one `qrk:` error. Linux tests isolate an empty ALSA configuration in the test child only. The optional CLI quiet probe uses a thread-scoped ALSA handler, restored afterward; no host settings or global stderr stream are changed.
- Stereo downmix is the **mean**, not the sum. Identical duplicated 48 kHz stereo and mono produce the same PCM and match confidence `0.6825031710161402`; 44.1 kHz mono gives `0.6814622716347675`. All accept 78:1. The former score of 1.0 was an uncalibrated CTC margin clipped at 1, not evidence of doubled stereo gain.
- Match confidence now uses `1 - exp(-max(0, margin))`; it is not a correctness probability and does not change acceptance thresholds. Raw-transcript confidence is the geometric mean of emitted-token peak posteriors, rather than constant zero; it cannot authorize completion.
- The existing 15 synthetic non-speech gates and 14 original owned-recording gain/chunk/wrong-target/truncation cases still pass with both models. These are regression gates, not population accuracy measurements.

Actual release-consumer outputs (all use the private two-ayah recording):

```text
PUBLIC TAGGED SWIFTPM 0.2.1 PASS: 114 surahs; v2 model pin; verse_match 78:1 AND 78:2
PACKAGED STDIO SIDECAR PASS verse_match 78:1 AND 78:2
PACKAGED NODE 0.2.1 PASS verse_match 78:1 AND 78:2
PACKAGED PYTHON 0.2.1 PASS verse_match 78:1 AND 78:2
DOTNET PASS (verses=[78:1,78:2])
```

The downloaded CLI also independently passes both boundary checks: target 78:1–1 returns only 78:1 with exit 0; wrong target surah 1 returns no verses, `needs_retry off_target`, and exit 1. Its stdio stdout remains JSON-only. The .NET consumer loads both the managed assembly and native library from the attached aggregate NuGet, rather than substituting a locally built engine.

## Release integrity

The reviewed Apple ZIP SHA-256 is `ad7f79e7cdbac3c41cc1453232da518f67adf4dc4d99774444bd37a1aa9ab38e`. GitHub's asset digest, both inline Swift manifests and `bindings/swift/binary-release.json` agree. The unpublished 0.2.1 tag was moved to checksum-pin commit `ae56e3ae67bc3d89f72dc56be9afc54a83ba7878` with the release workflow temporarily disabled and then re-enabled; archive bytes were not rebuilt after pinning.

The release has **15 assets**: four CLI/C archives, four Node archives, four Python wheels, one aggregate NuGet, the Apple ZIP and its checksum. Native release builders passed on Windows x64, Linux x64 and both Mac architectures; Apple packaging/tests passed. Implementation CI additionally passes Linux ARM source/native inference tests and the iOS example build. Linux ARM has source CI, not a promised downloadable archive.

The final checksum-pin CI completed successfully on 2026-11-02 at 01:38 UTC. Both full source runs and all release builders are green; later commits add Markdown verification receipts only.

| Final pin CI job | Result |
|---|---|
| macOS Apple silicon | Pass |
| macOS Intel | Pass |
| Windows x64 | Pass |
| Linux x64 | Pass |
| Linux ARM64 (source/native inference) | Pass |
| Swift tests, iOS Simulator example build, tagged SwiftPM dependency | Pass |

The release CLI/C archives for all four platforms contain the `yvezf` owner URL and no former-owner URL. Fourteen native files across those archives, the Apple-silicon Node/wheel and the four-RID NuGet were inspected; none contains the former owner. The Node library has no owner URL because its directory-based model loader does not link the downloader. Downloaded archive digests match GitHub's asset digests. [Binary integrity receipt](verification/release-0.2.1-assets.md).

## macOS signing and remaining limits

These downloads are not Developer-ID signed or notarized. README and release notes include the specific-file quarantine command and the supported per-file exception path. The audit's Finder right-click → Open path applies to older macOS; [Apple removed it in macOS 15](https://developer.apple.com/news/?id=saqachfa). On macOS 15+, use Privacy & Security → Open Anyway after the blocked launch. No global security setting is changed.

Developer-ID signing/notarization remains a follow-up requiring the owner's certificate/private key/password and notary credentials in repository secrets, plus a reviewed signing workflow. No certificate or notarization is claimed. npm/PyPI/NuGet registry publication remains separate from the attached packages.

These fixtures and local owned clips do not establish multi-reciter accuracy, Tajweed assessment or specific-iPhone runtime performance. Physical-microphone conditions remain distinct from deterministic file and silence tests. The Hear worktree was read only; no app or account settings were changed.
