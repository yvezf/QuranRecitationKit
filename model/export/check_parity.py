#!/usr/bin/env python3
"""Compare candidate v2 and v1 on synthetic signals. Failure never changes a default."""
import argparse,json
from pathlib import Path
import numpy as np
import onnxruntime as ort
from fixtures import named_signals
def collapse(a):
    result=[];prior=None
    for value in a:
        value=int(value)
        if value!=prior and value!=1024:result.append(value)
        prior=value
    return result
def main():
    p=argparse.ArgumentParser();p.add_argument('--v1',type=Path,required=True);p.add_argument('--v2',type=Path,required=True);p.add_argument('--report',type=Path,required=True);p.add_argument('--report-only',action='store_true',help='Record raw non-speech decoder compatibility without treating it as an acceptance decision');a=p.parse_args()
    options=ort.SessionOptions();options.intra_op_num_threads=2
    left=ort.InferenceSession(str(a.v1),options,providers=['CPUExecutionProvider']);right=ort.InferenceSession(str(a.v2),options,providers=['CPUExecutionProvider'])
    rows=[]
    for name,sample in named_signals():
        x=left.run(['log_probs'],sample)[0];y=right.run(['log_probs'],sample)[0]
        valid=x.shape==y.shape and x.shape[2]==1025 and np.isfinite(y).all()
        tokens_equal=valid and collapse(x.argmax(-1)[0])==collapse(y.argmax(-1)[0])
        rows.append({'fixture':name,'samples':int(sample['length'][0]),'shape_equal':x.shape==y.shape,'tokens_equal':bool(tokens_equal),'v1_tokens':collapse(x.argmax(-1)[0]),'candidate_tokens':collapse(y.argmax(-1)[0]),'max_absolute_logit_error':float(np.max(np.abs(x-y)))if valid else None})
    success=all(row['tokens_equal'] for row in rows)
    a.report.write_text(json.dumps({'synthetic_parity':success,'rows':rows,'release_authorized':False,'limitations':'Synthetic parity is necessary, not evidence of real-recitation accuracy. No model is promoted automatically.'},indent=2)+'\n')
    if not success and not a.report_only:raise SystemExit('Candidate failed raw decoder compatibility; v1 remains pinned.')
if __name__=='__main__':main()
