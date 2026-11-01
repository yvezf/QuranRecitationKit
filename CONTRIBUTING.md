# Contributing

Thanks for helping. A few ground rules keep this project easy to trust.

- **Licenses.** Code contributions are MIT. Do not add model weights, Qur'an text, or audio under any other terms without discussing first in an issue. Nothing derived from NPL-1.2 material (Quran-Lab Zipformer, phoneme corpora) can be merged — it is non-commercial share-alike and would change the license of the whole project.
- **No recitation audio in the repo.** Tests use synthetic logits and synthetic signals (`tests/fixtures/`). If you need real audio to verify a change, keep it local and describe the result in the PR.
- **Qur'an text is verbatim only.** `corpus/quran-uthmani.json` is Tanzil's text and is never edited. The normalized index is built at runtime; never commit a generated one.
- **One engine.** Behaviour lives in `core/qrk-core`. Bindings are thin; if you find yourself adding logic to a binding, it belongs in the core.
- **Build must stay green on all four CI targets** (macOS arm64/x64, Windows x64, Linux x64): `cargo fmt --check`, `cargo clippy -D warnings`, `cargo test --workspace`, plus each binding's own build.
- **Public API or protocol changes** go through a short design note in the PR, a `protocol/events.schema.json` update if events change, and a CHANGELOG entry.
- **Be kind in review.**

Run locally:

```sh
cd core && cargo fmt --check && cargo clippy --workspace -- -D warnings && cargo test --workspace
cargo run -p qrk-cli -- model fetch
cargo run -p qrk-cli -- wav --surah 1 path/to/your/own/fatiha.wav --json
```
