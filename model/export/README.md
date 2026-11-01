# Clean model v2 candidate pipeline

This manually triggered pipeline starts with NVIDIA's checkpoint and uses the Apache-2.0 NeMo/PyTorch preprocessing path. It does not reuse Cyberistic's custom exporter. It exports raw-waveform inputs and both CTC/encoder outputs, then calibrates an int8 candidate using synthetic signals only. The v1 model, hash and default are unchanged.

**Status: prepared, not executed locally or validated.** NeMo export support (notably STFT/complex lowering) must pass on the workflow runner. Export failure is not a usable artifact. Int4 is deliberately gated: apply ORT MatMulNBits only when supported and after parity evaluation; static int8 plus dynamic int4 is not assumed to preserve decisions.

Run `export_clean.py --out <local-directory>`, then `check_parity.py --v1 <local-v1-model> --v2 <candidate-int8.onnx> --report <report.json>`. The workflow records exact installed dependencies. No reciter audio is used, fetched, or shipped. Synthetic decision parity does not establish real-recitation accuracy or authorize publication. Review the report, test owned/local recordings, update model metadata and compatibility deliberately, and publish under a separate `model-v2` tag only after approval.
