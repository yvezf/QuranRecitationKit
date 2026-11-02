# Spot-mode verification — 2026-11-01

This is an engineering gate report for v0.3.0, not a classroom accuracy benchmark. The model remains the checksum-pinned NVIDIA-derived `model-v2`; this release adds runtime retrieval, acoustic verification, quotation events, and integration surfaces. No recordings or generated Qur'an indexes are included in the repository or SDK archives.

## Deterministic tests

The Rust workspace has 52 tests, including these quotation regressions:

- `shingle_index_known_trigram_and_cross_ayah_span`
- `disambiguation_common_phrase_returns_candidates_never_verdict`
- `display_spans_are_verbatim_tanzil_not_normalized`
- `frame_span_maps_to_absolute_audio_time`
- `synthetic_two_ayah_quote_between_noise_emits_once_with_times`
- `invalid_spot_config_cannot_lower_tracking_margin`
- `acoustic_repeated_ayah_is_ambiguous_without_a_selected_citation`
- `pronunciation_variant_is_verified_but_display_is_untouched`
- `complete_ayah_below_minimum_audio_duration_is_not_a_quote`
- `complete_single_word_ayah_uses_high_margin_exception`
- `runtime_spot_cache_roundtrip_and_corruption_rejection`
- `shared_single_word_ayah_never_becomes_a_unique_pick`

The synthetic two-ayah timeline produces exactly one quotation for 78:1–2, checks its times, and checks the one-forward-per-tick bound. Cache-corruption tests reject altered display Arabic. Configuration cannot lower the tracking margin. JSON Schema checks reject ambiguous quotations with a selected primary citation, including inside summaries.

## Private owned-recording checks

Two existing recordings were processed locally. Each was embedded after four seconds of seeded speech-shaped noise and followed by five seconds of noise. The carrier is synthetic, not a classroom recording. The gate checks correct references and that aligned times lie inside the inserted clip, with a half-second tolerance; it does not establish word-boundary accuracy against human annotations.

Rounded result log (audio is not distributed):

```json
{"case":"owned-one-ayah","type":"quote_detected","reference":"An-Naba 78:1","start_seconds":4.277,"end_seconds":8.495,"confidence":0.638,"verified":true,"ambiguous":false}
{"case":"owned-two-ayah","type":"quote_detected","reference":"An-Naba 78:1","start_seconds":4.277,"end_seconds":7.921,"confidence":0.459,"verified":true,"ambiguous":false}
{"case":"owned-two-ayah","type":"quote_detected","reference":"An-Naba 78:2","start_seconds":10.089,"end_seconds":13.099,"confidence":0.586,"verified":true,"ambiguous":false}
```

The second recording has a pause longer than the 1.2-second close threshold, so two events are the expected result. The contiguous synthetic fixture checks the single merged-event case separately. Confidence is a gate score, not a calibrated probability.

The existing five-case continuous-tracking regression also passes: the two-ayah recording accepts 78:1 and 78:2 for a two-ayah target, accepts only 78:1 for a one-ayah target even when audio continues, and rejects the wrong target. Spot mode does not weaken tracking acceptance.

## Negatives and integration checks

- Seeded noise produces no quotation.
- Locally synthesized English prose, Arabic prose, and a short incomplete common phrase produce no quotation in these tests.
- A locally synthesized basmala produces one ambiguous suggestion, confidence 0.5, with 1:1 and 27:30 alternatives and **null primary citation/text**. It is never eligible for automatic insertion.
- Transcript-only matching remains `verified:false`; common phrases return alternatives. No acoustic model is loaded for text matching.
- Native Node and Python bindings, .NET P/Invoke, Swift async events, stdio, and WebSocket transports were exercised locally with the owned two-ayah recording. Each returned both references; reset followed by silence returned no stale quotes.
- The same two-ayah recording converted to 44.1 kHz stereo and 48 kHz stereo also returned both references through the WAV/downmix/resampling path.
- Local suites: Node 7 tests; Python 6 tests; Swift 9 tests with the optional real-model/owned-audio gates enabled. The SwiftUI example builds for the generic iOS Simulator destination.
- The word-timestamp transcript example creates review-only replacement proposals, preserves surrounding prose, and ignores unverified/ambiguous detections.

Temporary converted audio and test consumers were removed after the checks. Audio never entered Git or release assets. Public tests use numeric synthetic fixtures or silence.

## Limits

Real-classroom precision and recall remain **unmeasured**. These gates do not prove performance for every accent, recitation style, microphone, room, language mixture, quotation length, or overlapping speaker. CTC times are approximate. A host should preserve the original transcript, show suggestions for review, and retain an easy correction path. Tanzil attribution is required when displaying the returned Arabic. See [integration and limits](SPOTTING.md).
