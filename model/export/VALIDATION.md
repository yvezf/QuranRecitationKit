# Candidate validation contract

No candidate changes the default automatically. Validation reports retain the model SHA-256, source checkpoint pin and environment. Recitation recordings stay local and never become workflow inputs or committed fixtures.

## Correcting the original measurement

The original `check_parity.py` gate compared collapsed greedy token strings on twelve pure sine waves. Those are non-speech inputs, not twelve Qur'an recitations. A general Arabic acoustic model can return arbitrary text on a tone. Equality of those strings is a decoder-compatibility diagnostic; it is not a recognition accuracy rate or proof that the recognizer accepted the sound as Qur'an.

That diagnostic remains available in strict mode and its original failure receipt is retained. The workflow's explicit `--report-only` invocation records every raw sequence and mismatch. It does not report mismatching strings as equal. Publication instead requires the source-fidelity and public-decision gates below. This changes the measurement to the actual expected-text recognition contract; it does not change the engine's acceptance policy, thresholds, expected words, or retry rules.

## Required gates

1. **Source integrity:** NVIDIA's checkpoint revision, byte count and SHA-256 must match `source.json` before restore.
2. **FP32 export fidelity:** the exported model must agree with the restored NVIDIA/NeMo forward pass on all twelve original tones and four seeded broadband signals. Both logits and encoder outputs must have matching shapes, finite values and maximum absolute error at most 0.005. The tolerance is fixed before running the check. Failed source fidelity stops quantization.
3. **Native public decisions:** the Rust recognizer evaluates the baseline and exact candidate bytes on Linux, Windows, Apple Silicon Mac and Intel Mac. Every original tone must produce no accepted verse and an explicit retry, matching the baseline's rejection decision. Silence, very short input and DC offset must also reject. Any exception, crash, acceptance of non-speech, or acceptance-decision mismatch fails the job. Raw decoder strings and uncalibrated confidence floats are not substituted for accepted-verse decisions. Exact retry-subtype matches are reported separately: `noise` versus `off_target` on a sound with no speech is an advisory classification, not a different accepted/rejected result. Neither subtype is a verdict on someone's recitation. Differences are retained in each case rather than reported as identical.
4. **Local owner recording:** the exact artifact must produce `verse_match 78:1` for the owner's recording at three gains and three feed chunk sizes. Four wrong-surah targets and a 100 ms truncation must produce no accepted verse. A missing recording is not a pass. No audio, PCM, logits from that recording, or personal paths are published.
5. **Release integration:** the promoted hash must be used by the downloader, tested in native inference, packaged for supported platforms and checksum-pinned for SwiftPM. The old model stays available as the previous release.

`core/qrk-cli/examples/validate_model.rs` is the independent public-event validator. It verifies candidate bytes against the explicit candidate receipt; it does not bypass or alter the SDK's default downloader pins. `--wav` is a local-only option and is never present in the hosted workflow.

## Compression correction

The first candidate statically calibrated speech activations using sine waves and quantized all Conv/MatMul activations. Besides decoder drift, that candidate raised a QLinearMatMul runtime error on Apple Silicon. It is not eligible for release.

The replacement uses Microsoft's ONNX Runtime tools: dynamic int8 convolution and symmetric int4 constant MatMul weights (block size 128). It needs no activation-calibration recordings or tones. NVIDIA/NeMo still provides the preprocessing and encoder; no other project's exporter or preprocessing source is imported. The smaller representation is not assumed accurate: it must pass all gates above.

The suite establishes behavior on the stated fixtures and platform runtimes. It is not a population accuracy benchmark or a Tajweed assessment.
