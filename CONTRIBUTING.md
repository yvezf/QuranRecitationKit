# Contributing

Code contributions are MIT. Keep recognition independent of host UI and product policy. Public API changes need a design note and changelog entry.

- Do not commit model weights or any recitation recording, PCM, spectrogram or embedding. Tests use synthetic logits/signals; keep real-audio checks local.
- Preserve third-party licenses and provenance. Do not import material from non-commercial model/corpus lines.
- Arabic source strings in `Tools/data/quran-uthmani.json` must remain verbatim. Never hand-edit the matching index: regenerate with the pinned tokenizer and run `Tools/verify_token_map.sh`. Review Tanzil's additional terms before changing distribution.
- No telemetry or release logging. Never put credentials, machine paths, device IDs or account configuration into source or test fixtures.
- Keep documentation consistent with implemented products. Cross-platform plans must not be advertised as completed bindings.

Run `swift build -v`, `swift test -v`, the token-map verifier, and the example simulator build from the README before a pull request. Tests do not download models or require audio. Use `QRK_MODEL_DIR` only for an additional opt-in local model test.
