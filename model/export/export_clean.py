#!/usr/bin/env python3
"""Candidate v2 export using NVIDIA/NeMo preprocessing, never Cyberistic's exporter.

This is an experimental, manually run export gate. It does not publish or change v1.
A failed Torch/NeMo export is a failed candidate, not permission to substitute a graph.
"""
import argparse, gc, hashlib, json, subprocess, sys
from pathlib import Path
import torch
import onnx
from nemo.collections.asr.models import EncDecHybridRNNTCTCBPEModel
from fetch_checkpoint import source_descriptor, verify_checkpoint
from quantize_clean import quantize
from check_source_fidelity import check as check_source_fidelity
HIDDEN='/encoder/layers.16/norm_out/LayerNormalization_output_0'
class RawAudioCTC(torch.nn.Module):
    def __init__(self,model):
        super().__init__();self.model=model
    def forward(self,audio_signal,length):
        # Stable log-mel accumulation keeps near-empty spectral bins from
        # amplifying FP32 FFT rounding. The licensed NeMo implementation is
        # unchanged; the neural encoder/decoder still run in FP32.
        features,feature_length=self.model.preprocessor(input_signal=audio_signal.to(torch.float64),length=length)
        encoded,encoded_length=self.model.encoder(audio_signal=features.to(torch.float32),length=feature_length)
        return self.model.ctc_decoder(encoder_output=encoded),encoded.transpose(1,2)
def main():
    p=argparse.ArgumentParser();p.add_argument('--out',type=Path,required=True);p.add_argument('--checkpoint',type=Path);args=p.parse_args();args.out.mkdir(parents=True,exist_ok=True)
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
    # Use Torch 2.7's native opset. Keep ONNXScript/IR versions pinned together;
    # finalization must inline local functions before version conversion.
    torch.onnx.export(wrapper,(wave,length),str(source),input_names=['audio_signal','length'],output_names=['log_probs',HIDDEN],dynamic_axes={'audio_signal':{1:'N'},'log_probs':{1:'T'},HIDDEN:{1:'T'}},opset_version=18,dynamo=True,external_data=False)
    onnx.checker.check_model(str(source))
    check_source_fidelity(wrapper,source,args.out/'source-fidelity.json')
    del wrapper,model,wave,length
    gc.collect()
    quantized=args.out/'candidate-mixed.onnx'
    quantize(source,quantized)
    metadata={'status':'candidate-unvalidated','base':'NVIDIA stt_ar_fastconformer_hybrid_large_pcd_v1.0','source':source_receipt,'file':quantized.name,'sha256':hashlib.sha256(quantized.read_bytes()).hexdigest(),'size':quantized.stat().st_size,'preprocessing':'NVIDIA NeMo with float64 log-mel accumulation, float32 encoder/decoder','quantization':'dynamic int8 convolution; symmetric int4 constant MatMul, block 128','calibration':'none; no reciter audio or non-speech activation calibration'}
    (args.out/'candidate.json').write_text(json.dumps(metadata,indent=2)+'\n')
    (args.out/'environment.txt').write_text(subprocess.check_output([sys.executable,'-m','pip','freeze'],text=True))
if __name__=='__main__':main()
