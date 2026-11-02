# Spot recall fixes prepared for 0.3.1

This is a source-patch verification report, not a classroom accuracy benchmark or a new binary-release claim. Published 0.3.0 assets and all existing tags remain unchanged. The larger multi-reciter benchmark remains [unmeasured](SPOT-EVAL-2026-11.md); no new version is tagged by this work.

## What changed

A unique, verified quotation seed can recover the start of its partially retrieved leading ayah, or the immediately preceding ayah in the same surah. The preceding ayah is scored independently with the existing confusers, duration and margin gates before the combined span is scored. A strong seed cannot compensate for an inaudible preceding ayah. Confidence uses the minimum of the seed, prefix and combined margins. Previously closed citations are not silently rewritten or duplicated.

Two independently verified, canonically adjacent spans can merge while open when their gap is within the existing 1.2-second silence boundary. Nonadjacent ayahs, different surahs and longer gaps remain separate. Display text is still sliced from unchanged Tanzil text; no generated quotation text is substituted.

Spotting's word-time bounds now exclude nonlexical punctuation/diacritic tails. Those frames previously stretched the candidate's scoring region and diluted the margin of short complete ayahs in longer windows. The raw decoder and expected-passage tracker's timing path are unchanged. There is still one model forward per tick; backward verification reuses that forward's logits.

Closed ambiguous phrases do not contribute a selected canonical span to the closed-span mask. Otherwise one alternative could be suppressed and another could appear unique in the next window. A later overlapping quote that adds no words beyond an already emitted ambiguous phrase cannot become a primary citation merely because the shortlist changed. This guard covers common phrases generally, with basmala regressions at both 8 and 12 seconds.

The minimum margin (0.035), complete-short-ayah margin (0.20), minimum duration (1.5 seconds), minimum distinct-word count (3) and ambiguity margin (0.05) are unchanged.

## Identical synthetic fixtures, before and after

The baseline is the original `spot.rs` from `82d0ef5`, byte-identical to that file at published tag `v0.3.0` (SHA-256 `fb18a9ef55e21116990d197a50d702e1ec17c38d69799b5a05702fa8420aa7f1`). Both implementations ran the same fixture module/configuration against the runtime corpus and tokenizer. No audio, recorded posteriors or generated Qur'an index is committed.

| Controlled condition | Window | Before complete-ayah coverage | After complete-ayah coverage | Event behavior |
|---|---:|---:|---:|---|
| Verified 78:2 seed; preceding 78:1 acoustically supported but misdecoded greedily | 8 s | 1/2 | 2/2 | One complete 78:1–2 span after recovery |
| Same condition through overlapping streaming windows | 8 s | 1/2 | 2/2 | Exactly one event and one summary citation |
| Short 78:1 with a nonlexical decoded tail | 6 s | 1/1 | 1/1 | Times preserved |
| Same short-ayah condition | 8 s | 1/1 | 1/1 | Times preserved |
| Same short-ayah condition | 12 s | 0/1 | 1/1 | No confidence dilution from the tail |
| Strong 78:2 seed, preceding 78:1 acoustically absent | 8 s | 1/1 | 1/1 | Zero fabricated preceding ayahs before/after |
| Two already verified adjacent ayahs, 0.8 s gap | 8 s | 2/2 | 2/2 | Two events before; one 78:1–2 event after |
| Closed ambiguous basmala followed by a unique quotation | 8 s | 1/1 seed | 1/1 seed | Erroneous primary citations: 1 before, 0 after |
| Same ambiguity-transition condition | 12 s | 1/1 seed | 1/1 seed | Erroneous primary citations: 1 before, 0 after |

The fixed-posterior short-ayah fixture returns the same start, end and confidence across all three window sizes. Backward recovery returns verbatim 78:1–2 at 6.40–12.24 seconds; the streaming version ends at approximately 12.28 seconds. The short ayah is at 22.04–24.76 seconds. Synthetic timing assertions allow 0.25 seconds; these are not human-annotated acoustic timestamps.

Regression tests also keep gaps above 1.2 seconds, nonadjacent ayahs and different surahs separate. Existing ambiguity, repeated-ayah, minimum-duration and wrong-target tracking tests remain in the suite.

### Reproduce the fixture receipts

```sh
cargo test --manifest-path core/Cargo.toml -p qrk-core spot::recall_tests -- --nocapture
python3 tools/report_spot_recall.py --before before.log --after after.log --output comparison.json
```

The report tool rejects changed fixture expectations, missing conditions, missed after-targets, regressions and false-positive receipts. The baseline run intentionally fails the new regression assertions. Recorded numeric results are in [the comparison receipt](verification/spot-recall-0.3.1.json).

## Local native-model check

A separate deterministic audio carrier uses two privately held clips at offsets 6 and 22 seconds. It contains seeded speech-shaped noise (seed 3101) and a four-tap room response: gains 1.0, 0.20, 0.11 and 0.055 at delays 0, 1273, 2837 and 4561 samples (16 kHz). All temporary audio remains outside the repository and is removed after the run.

| Native condition | Before | After |
|---|---:|---:|
| Reverberant carrier, 8 s window: three expected ayah occurrences | 3/3 | 3/3 |
| Same carrier, 12 s window | 3/3 | 3/3 |
| Thirty seconds of noise, 8 s window: quotation events | 0 | 0 |
| Thirty seconds of noise, 12 s window: quotation events | 0 | 0 |

This independently constructed carrier already passed before the patch; it is not presented as a reproduction of every reported room condition. Natural pauses beyond the close boundary can legitimately produce separate native citations. The controlled posterior fixtures isolate the two failure mechanisms and the publication-merge boundary.

A second native check places synthesized Arabic prose, a basmala, or a repeated 78:2 immediately before an isolated privately held 78:2 clip. At both 8- and 12-second windows, the fixed engine retains the real seed and never invents 78:1. In the basmala condition the old engine incorrectly promoted an ambiguous phrase to a primary 1:1 citation; the fixed engine preserves its ambiguity.

| Native neighbor condition | Window | Before erroneous primary citations | After erroneous primary citations | Real 78:2 seed after |
|---|---:|---:|---:|---:|
| Basmala followed by isolated 78:2 | 8 s | 1 | 0 | Found |
| Same condition | 12 s | 1 | 0 | Found |
| Arabic prose or repeated 78:2 (four runs total) | 8 / 12 s | 0 | 0 | Found in all four |

Post-fix local OS speech synthesis checks also return no quotes for English prose, Arabic prose or an incomplete common phrase. A basmala returns ambiguous alternatives with no selected primary citation, preserving its existing behavior. These are synthetic voices, not classroom speakers.

The local Rust workspace has 61 passing tests; formatting and Clippy with warnings denied pass. Cross-platform CI is required before merging the source patch.

These small gates do not establish multi-reciter precision, partial-quote recall or real-classroom accuracy. Acceptance thresholds have not been tuned to these owned clips. The larger release-quality gate remains unverified, as documented in SPOT-EVAL-2026-11.md.
