# Architecture

```text
Host PCM / explicit microphone capture
  → bandlimited resample (Rust adapter) → mono 16 kHz f32
  → qrk-onnx (CPU default) → CTC log probabilities [T,1025]
  → qrk-core expected-text session + forced alignment + acceptance → events
      ├ C ABI → Swift actor / .NET P/Invoke
      ├ napi-rs → Node EventEmitter
      ├ PyO3 → Python returned events / callback
      └ qrk helper → localhost WebSocket / stdio → any host language
```

`qrk-core` has no normal file/network/hardware I/O. A generic `AcousticModel` seam accepts synthetic runners. `qrk-onnx::Recognizer` supplies model loading and the concrete runner, avoiding a dependency cycle. The model's second output remains exposed but the current runner requests only CTC log probabilities. No endpoint classifier is trained or shipped.

The corpus contains 114 surahs / 6,236 ayahs of verbatim Tanzil Arabic with attribution. Startup creates a normalized/tokenized in-memory index and ayah-level confusers; `qrk-onnx` optionally caches it in the user's app cache, keyed by corpus/tokenizer/index version. No generated matching index ships. NVIDIA's actual SentencePiece **Unigram** tokenizer is converted to `tokenizer.json`; 77,441 source word checks found zero tokenization differences. Public targets are ayahs or zero-based half-open word ranges, independent of app visual line wrapping. Internal acoustic spans are bounded to eight words; only completed requested units produce verse-match events.

The session retains at most 2–12 seconds of PCM and evaluates synchronously at feed boundaries. Bindings should feed roughly 300 ms chunks and await/serialize each call. The Node binding runs inference on a native worker and caps queued commands; Python releases the GIL; Swift uses an actor; .NET executes on the caller's worker. There is no inherited Swift latest-only inference mailbox in the new engine. Provisional word highlighting is deliberately weaker than acceptance; the summary is authoritative for accepted verses. CTC identity margins, ordered word coverage, speech floors, silence and stability gate acceptance; noise/uncertain input yields a neutral retry, not a Tajweed accusation. These are heuristic safeguards, not a measured accuracy guarantee.

Pronunciation variants are restricted by surah/ayah/word and source token sequence. Standalone Muqattaat positions have exact suffix fences, longer speech floors and repeated-evidence requirements. Changing acceptance policy or the model requires new synthetic and real-audio evaluation.

The C ABI owns opaque, mutex-protected sessions. Strings in callbacks are borrowed for that call; summary/metadata strings are owned and explicitly freed. Native wrappers copy JSON before returning to host callbacks. No handle may be freed concurrently with a C call. Safe bindings serialize lifetime operations; callers must not re-enter a session from its callback. Swift's event stream buffers 512 recent events, while stop returns all accepted verses. Hosts should consume progress promptly.

Apple archives link the pinned Microsoft CPU runtime statically and contain iOS arm64, Simulator arm64/x64 and universal macOS. Desktop distributions can embed the official platform runtime bytes, validate their hash and extract them to user-local cache. This is a self-contained helper distribution rather than a claim that every desktop ONNX dependency is statically linked. Windows VC++ runtime prerequisites may apply. Optional CoreML/DirectML paths exist but CPU is the verified default.

`qrk serve` binds 127.0.0.1 only, bounds messages/sessions and optionally requires a bearer token. Unauthenticated remote browser Origins are rejected; native/file clients remain possible. Audio/model inference stays local. Downloads are explicit, HTTPS and SHA/size pinned. No app backend, analytics, account, billing, product entitlement or garden state crosses the SDK boundary.
