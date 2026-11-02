# Spot evaluation — November 2026

## Status: release-quality gate not evaluated

The requested large multi-reciter benchmark could not be constructed from the two proposed datasets under the stated rule to use audio only when its license is clearly permissive. Only cards and repository metadata were retrieved. No dataset audio, phoneme corpus, embeddings or weights were downloaded for this evaluation.

| Dataset | Exact checked revision | Recording-license finding | Decision |
|---|---|---|---|
| [tarteel-ai/everyayah](https://huggingface.co/datasets/tarteel-ai/everyayah/blob/6ea510862d64f59e555a4a8363eebc0f415621df/README.md) | `6ea510862d64f59e555a4a8363eebc0f415621df` | The card distinguishes its CC BY 4.0 remainder from individual recordings, whose licensing it says is undocumented. It does not grant an MIT audio license. | Audio skipped |
| [greentechapps/everyayah_curated_1s_20s](https://huggingface.co/datasets/greentechapps/everyayah_curated_1s_20s/blob/235a08d5acd02709e0ecb2e48aad49797f108e10/README.md) | `235a08d5acd02709e0ecb2e48aad49797f108e10` | The card contains dataset/configuration metadata but no license field or recording-license grant. No separate license file was listed. | Audio skipped |

An unrelated project's notice is not evidence that a dataset contributor can license each recording. A label for dataset metadata also cannot establish recording rights. These findings concern the specified revisions, not every possible future release of these datasets.

## Requested gates

`N/A` means no qualifying benchmark was run; it does not mean zero errors or a passing gate.

| Condition | Precision | Recall | Start/end time error | Required gate | Result |
|---|---|---|---|---|---|
| All qualifying conditions | N/A | N/A | N/A | Overall precision ≥ 0.95 | Not evaluated |
| Full-ayah clear quotations | N/A | N/A | N/A | Recall ≥ 0.90 | Not evaluated |
| Partial quotations, ≥ 3 distinct words | N/A | N/A | N/A | Recall ≥ 0.75 | Not evaluated |
| Room reverb | N/A | N/A | N/A | Report separately | Not evaluated |
| Distant-microphone gain/noise | N/A | N/A | N/A | Report separately | Not evaluated |
| Negative set | N/A | N/A | N/A | Zero false positives | Not evaluated |

Qualifying external clips downloaded: **0**. Qualified external reciters: **0/5 required**. Licensed all-surah opening coverage in this proposed benchmark: **0/114**. There is no aggregate classroom or multi-reciter precision/recall claim.

The smaller [development verification](SPOTTING-VERIFICATION-2026-11-01.md) remains separate: synthetic logits, two privately held clips in a seeded noise carrier, resampling, and locally synthesized negative speech. Those checks do not meet this benchmark's size, human-reciter diversity, partial-quote coverage or room-condition requirements. Their successful results must not be promoted into a release-quality precision/recall score.

## Predeclared method for a qualifying local benchmark

1. Pin the dataset revision, recording-specific permission and clip selection before downloading. Select several hundred clips from at least five reciters, all 114 surah openings and a spread of ayah lengths. Keep all audio/annotations outside Git and uploads. Divide development and held-out evaluation by reciter/clip before tuning.
2. Generate deterministic carrier tracks from permitted speech or generated English/Arabic speech-shaped noise. Insert one to three quotation spans at known offsets. Include full ayahs, contiguous multi-ayah passages and first-half partial quotes with at least three distinct words. Preserve exact sample-to-second clocks and canonical word ranges.
3. Apply a documented, seeded impulse response for reverb and a separately recorded gain/noise condition for distant microphones. Keep clean, reverberant and distant conditions separate in the report. Do not tune on the held-out results.
4. Include non-Qur'an Arabic, non-Qur'anic du'a, English and short/common phrases. A du'a that actually quotes Qur'an is not a negative merely because it is used as a du'a. Ambiguous/unverified suggestions are recorded separately and never treated as a selected primary citation.
5. Score one-to-one citation/span matches with a predeclared time-overlap rule; report verified-primary precision, full/partial recall, ambiguity/abstention counts, false positives per negative recording and median/p95 absolute start/end error. Also report missed and duplicate citations. Compare returned text to unchanged canonical Tanzil spans.
6. Tune only through this harness on the development partition. Freeze settings and rerun the held-out partition once; retain all failures. Passing synthetic conditions still does not establish performance in actual classrooms.

## Release chronology

Version 0.3.0 was already public when this additional benchmark requirement arrived. Its existing assets are preserved; its history was scrubbed as requested. This work does not pretend that an already published tag passed a benchmark that did not run. No new SDK/model version is tagged from this hardening work while the new evaluation gate remains unverified. Spot acceptance thresholds are unchanged.
