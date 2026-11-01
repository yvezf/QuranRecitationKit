"""Check the FP32 export against the actual restored NVIDIA/NeMo forward pass."""
import json
from pathlib import Path

import numpy as np
import onnxruntime as ort
import torch

from fixtures import named_signals


def check(wrapper, source, report):
    options = ort.SessionOptions()
    options.intra_op_num_threads = 2
    session = ort.InferenceSession(str(source), options, providers=["CPUExecutionProvider"])
    fixtures = list(named_signals())
    rng = np.random.default_rng(20261101)
    for samples in (16000, 32000, 48000, 192000):
        fixtures.append((f"broadband-{samples}", {
            "audio_signal": rng.normal(0, 0.05, (1, samples)).astype(np.float32),
            "length": np.array([samples], np.int64),
        }))
    unfused_options = ort.SessionOptions()
    unfused_options.intra_op_num_threads = 2
    unfused_options.graph_optimization_level = ort.GraphOptimizationLevel.ORT_DISABLE_ALL
    unfused_session = ort.InferenceSession(str(source), unfused_options, providers=["CPUExecutionProvider"])
    rows = []
    for name, sample in fixtures:
        with torch.no_grad():
            expected = wrapper(torch.from_numpy(sample["audio_signal"]), torch.from_numpy(sample["length"]))
        actual = session.run(None, sample)
        unfused = unfused_session.run(None, sample)
        with torch.no_grad(), torch.backends.mkldnn.flags(enabled=False):
            torch_unfused = wrapper(torch.from_numpy(sample["audio_signal"]), torch.from_numpy(sample["length"]))
        errors = []
        shapes = True
        finite = True
        for left, right in zip(expected, actual, strict=True):
            left = left.detach().cpu().numpy()
            shapes = shapes and left.shape == right.shape
            finite = finite and bool(np.isfinite(left).all() and np.isfinite(right).all())
            errors.append(float(np.abs(left-right).max()) if left.shape == right.shape else None)
        passed = shapes and finite and all(error is not None and error <= 0.005 for error in errors)
        rows.append({"fixture":name,"shapes_equal":shapes,"finite":finite,
                     "maximum_absolute_errors":errors,"passed":passed,
                     "unfused_ort_errors":[float(np.abs(l.detach().cpu().numpy()-r).max()) for l,r in zip(expected,unfused,strict=True)],
                     "unfused_torch_errors":[float(np.abs(l.detach().cpu().numpy()-r).max()) for l,r in zip(torch_unfused,actual,strict=True)],
                     "log_probability_argmax_frames_equal":bool(np.array_equal(expected[0].detach().cpu().numpy().argmax(-1),actual[0].argmax(-1))),
                     "maximum_probability_error":float(np.abs(np.exp(expected[0].detach().cpu().numpy())-np.exp(actual[0])).max())})
    passed = all(row["passed"] for row in rows)
    Path(report).write_text(json.dumps({"passed":passed,"maximum_allowed_absolute_error":0.005,
        "reference":"Restored, hash-pinned NVIDIA checkpoint through NeMo; FP32 output and encoder state",
        "rows":rows}, indent=2)+'\n')
    if not passed:
        raise RuntimeError("FP32 export failed NVIDIA source fidelity; quantization is not authorized")
