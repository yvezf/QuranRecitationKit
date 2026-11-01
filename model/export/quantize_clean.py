#!/usr/bin/env python3
"""Calibration-free CPU compression using Microsoft's licensed quantizers.

Dynamic int8 convolution and symmetric int4 constant MatMul weights keep
activation ranges input-dependent. This never calibrates speech activations
against non-speech tones, and never imports another project's exporter.
"""
import argparse
import gc
from pathlib import Path
import tempfile

import onnx
from onnxruntime.quantization import QuantType, quantize_dynamic
from onnxruntime.quantization.matmul_nbits_quantizer import (
    DefaultWeightOnlyQuantConfig,
    MatMulNBitsQuantizer,
)
from onnxruntime.quantization.shape_inference import quant_pre_process


def quantize(source, destination):
    source, destination = Path(source), Path(destination)
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="qrk-quantize-", dir=destination.parent) as work:
        work = Path(work)
        prepared = work / "prepared.onnx"
        conv = work / "conv-dynamic-int8.onnx"
        quant_pre_process(source, prepared, skip_symbolic_shape=True)
        quantize_dynamic(
            prepared, conv,
            weight_type=QuantType.QInt8,
            per_channel=False,
            op_types_to_quantize=["Conv"],
        )
        model = onnx.load(str(conv))
        quantizer = MatMulNBitsQuantizer(
            model,
            algo_config=DefaultWeightOnlyQuantConfig(
                block_size=128, is_symmetric=True, bits=4,
            ),
        )
        quantizer.process()
        quantizer.model.save_model_to_file(str(destination), use_external_data_format=False)
        del model, quantizer
        gc.collect()
    onnx.checker.check_model(str(destination))


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    quantize(args.source, args.out)
