#!/usr/bin/env python3
"""Candidate v2 export using NVIDIA/NeMo preprocessing, never Cyberistic's exporter.

This is an experimental, manually run export gate. It does not publish or change v1.
A failed Torch/NeMo export is a failed candidate, not permission to substitute a graph.
"""
import argparse, hashlib, json, subprocess, sys
from pathlib import Path
import numpy as np
import torch
import onnx
from nemo.collections.asr.models import EncDecHybridRNNTCTCBPEModel
from onnxruntime.quantization import CalibrationDataReader, QuantFormat, QuantType, quantize_static
from fetch_checkpoint import source_descriptor, verify_checkpoint
HIDDEN='/encoder/layers.16/norm_out/LayerNormalization_output_0'
class RawAudioCTC(torch.nn.Module):
    def __init__(self,model):
        super().__init__();self.model=model
    def forward(self,audio_signal,length):
        features,feature_length=self.model.preprocessor(input_signal=audio_signal,length=length)
        encoded,encoded_length=self.model.encoder(audio_signal=features,length=feature_length)
        return self.model.ctc_decoder(encoder_output=encoded),encoded.transpose(1,2)
def signals():
    for samples in (16000,32000,48000,192000):
        t=np.arange(samples,dtype=np.float32)/16000
        for frequency in (110,220,440):
            yield {'audio_signal':(0.02*np.sin(2*np.pi*frequency*t)).astype(np.float32)[None,:],'length':np.array([samples],np.int64)}
class Calibration(CalibrationDataReader):
    def __init__(self):self.samples=iter(signals())
    def get_next(self):return next(self.samples,None)
def main():
    p=argparse.ArgumentParser();p.add_argument('--out',type=Path,required=True);p.add_argument('--checkpoint',type=Path);p.add_argument('--int4',action='store_true');args=p.parse_args();args.out.mkdir(parents=True,exist_ok=True)
    checkpoint=args.checkpoint
    if checkpoint is None:
        checkpoint=args.out.parent/'checkpoint'/'nvidia.nemo'
        subprocess.run([sys.executable,str(Path(__file__).with_name('fetch_checkpoint.py')),'--out',str(checkpoint)],check=True)
    source_receipt=source_descriptor()
    verify_checkpoint(checkpoint,source_receipt)
    (args.out/'source.json').write_text(json.dumps(source_receipt,indent=2)+'\n')
    model=EncDecHybridRNNTCTCBPEModel.restore_from(str(checkpoint),map_location='cpu')
    model.eval();model.freeze();model.preprocessor.featurizer.dither=0.0
    if hasattr(model.preprocessor.featurizer,'pad_to'):model.preprocessor.featurizer.pad_to=0
    wrapper=RawAudioCTC(model).eval();wave=torch.zeros((1,32000),dtype=torch.float32);length=torch.tensor([32000],dtype=torch.int64)
    source=args.out/'full-precision.onnx'
    # Dynamo handles supported complex/STFT decompositions. Unsupported export fails here.
    torch.onnx.export(wrapper,(wave,length),str(source),input_names=['audio_signal','length'],output_names=['log_probs',HIDDEN],dynamic_axes={'audio_signal':{1:'N'},'log_probs':{1:'T'},HIDDEN:{1:'T'}},opset_version=20,dynamo=True,external_data=False)
    onnx.checker.check_model(onnx.load(str(source)))
    quantized=args.out/'candidate-int8.onnx'
    quantize_static(str(source),str(quantized),Calibration(),quant_format=QuantFormat.QDQ,activation_type=QuantType.QInt8,weight_type=QuantType.QInt8,per_channel=True,op_types_to_quantize=['Conv'] if args.int4 else ['Conv','MatMul'])
    if args.int4:
        from onnxruntime.quantization.matmul_nbits_quantizer import MatMulNBitsQuantizer, DefaultWeightOnlyQuantConfig
        fourbit=MatMulNBitsQuantizer(onnx.load(str(quantized)),algo_config=DefaultWeightOnlyQuantConfig(block_size=128,is_symmetric=True,bits=4))
        fourbit.process()
        fourbit.model.save_model_to_file(str(quantized),use_external_data_format=False)
    onnx.checker.check_model(onnx.load(str(quantized)))
    metadata={'status':'candidate-unvalidated','base':'NVIDIA stt_ar_fastconformer_hybrid_large_pcd_v1.0','source':source_receipt,'sha256':hashlib.sha256(quantized.read_bytes()).hexdigest(),'size':quantized.stat().st_size,'calibration':'deterministic synthetic sine signals only; no reciter audio','int4':bool(args.int4)}
    (args.out/'candidate.json').write_text(json.dumps(metadata,indent=2)+'\n')
    (args.out/'environment.txt').write_text(subprocess.check_output([sys.executable,'-m','pip','freeze'],text=True))
if __name__=='__main__':main()
