# Changelog

## 0.1.0 — 2026-11-01

Initial standalone Swift implementation, prepared for local review before publication.

- `QuranRecitationKit`: expected-text recognition actor, event stream, ayah/word-range targets, verified model packs, Quran text catalog and bounded inference scheduling.
- `QuranRecitationAudio`: optional microphone capture, streaming mono resampling, synchronous stop and asynchronous stop-and-drain.
- `recite-cli`: local PCM16/Float32 WAV recognition on macOS.
- `Example/RecitationDemo`: iOS 16 SwiftUI host with model download, recording and word progress.
- Synthetic regression tests ported from the existing detector, package/lifecycle tests and an opt-in ONNX integration test.
- Schema 2 token index: ayah-based segmentation, regenerated confusers, verbatim display Arabic and names. Matching words/tokens retain their prior values.
- Balanced/conservative/lenient endpoint presets; confidence is explicitly uncalibrated.
- Corrected source-commit/model-release provenance and documented unresolved export/index redistribution questions.

The model release and remote repository are not created by this implementation. No Windows/Linux or language bindings are claimed.
