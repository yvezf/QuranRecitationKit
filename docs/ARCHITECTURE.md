# Architecture

```text
Microphone / WAV / host PCM
  -> 16 kHz mono Float32
  -> RecitationRecognizer actor
  -> RecognitionSession: bounded ring + newest/terminal mailbox + generation fences
  -> OnnxRunner: serial ONNX Runtime queues, bounded pending requests
  -> CTC logits -> greedy decode -> ordered word support + target/confuser CTC comparison
  -> endpoint/identity policy -> RecitationEvent -> host UI

RecitationTarget -> validated ayah catalog -> canonical word windows
ModelPack -> independently pinned model file
Bundle.module -> vocabulary, ayah index, manifests
```

`QuranRecitationKit` owns no microphone, UI, product state, or durable recitation history. `QuranRecitationAudio` supplies optional capture. The CLI reads local WAV files; the example is a plain host UI.

The engine buffers at most 12 seconds of PCM and offers immutable snapshots after 3,200 fresh samples. ONNX inference is asynchronous on a serial queue. The retained mailbox has one latest-in-policy snapshot and one terminal snapshot; reset and retarget increment a generation so stale results cannot advance a new passage. Model downloads use the runner's tested task-lease ledger to coalesce callers safely.

The public canonical unit is an ayah. Its token boundaries are independent of rendered font/line wrapping. Long ayahs use bounded internal acoustic spans, with ordered identity-backed progression and completion only on the selected ayah's final span. Greedy emission timing scopes candidate comparisons to the current span when exact observed support exists; forced alignment alone cannot manufacture completion.

CTC scores and fuzzy ordered text support are recognition evidence, not a Tajweed judgement. The default policy retains the legacy content margin, endpoint and speech-span thresholds, but scheduling is adapted to standalone ayahs. It is not a claim of full parity with the former product's UI line scheduling. See [SWIFT-IMPLEMENTATION.md](SWIFT-IMPLEMENTATION.md) for the exact public API, presets, buffering contract and deviations.

`Tools/generate_token_map.py` derives a deterministic index from verbatim Arabic and NVIDIA's pinned tokenizer. Schema 2 uses one ayah boundary per record and regenerates nearest-confuser rows for 6,236 ayahs. The previous index's normalized words, token IDs and word-token boundaries are preserved. Original Arabic display strings and surah metadata are included in the new index. No translation or reciter recording is included.

Optional endpoint feature extraction remains a pure, parity-tested helper; there is no trained pronunciation classifier in this package. Experimental continuous-authority rollout and product adapters were removed. There are no Rust crates, sidecar protocols or non-Apple bindings in this implementation.
