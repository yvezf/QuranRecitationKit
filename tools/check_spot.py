#!/usr/bin/env python3
"""Cross-platform public CLI/stdio/schema contract; no recorded audio or microphone."""
from pathlib import Path
import base64,json,os,subprocess
from jsonschema import Draft202012Validator
root=Path(__file__).resolve().parent.parent
binary=root/'core/target/release'/('qrk.exe' if os.name=='nt' else 'qrk')
validator=Draft202012Validator(json.loads((root/'protocol/events.schema.json').read_text()))
for text in ['الذين آمنوا','The teacher explains the timetable']:
 r=subprocess.run([str(binary),'match-text',text,'--json'],capture_output=True,text=True,encoding="utf-8",check=True)
 result=json.loads(r.stdout);assert result['verified'] is False
 if text.startswith('الذين'):assert result['ambiguous'] and len(result['candidates'])>=2
 else:assert result['candidates']==[]
model=os.environ.get('QRK_MODEL_DIR')
if not model:raise SystemExit('QRK_MODEL_DIR must be set by the explicit model-fetch gate')
commands=[{'type':'match_text','text':'الذين آمنوا'},{'type':'start','mode':'spot','format':'f32le','sample_rate':16000},{'type':'audio','data':base64.b64encode(bytes(32000*4)).decode()},{'type':'stop'}]
r=subprocess.run([str(binary),'--model',model,'serve','--stdio'],input=''.join(json.dumps(v)+'\n' for v in commands),capture_output=True,text=True,encoding="utf-8",check=True,timeout=120)
events=[json.loads(line) for line in r.stdout.splitlines()]
for event in events:validator.validate(event)
assert not any(e['type'] in ['error','quote_detected'] for e in events),events
assert next(e for e in events if e['type']=='text_match')['verified'] is False
assert next(e for e in events if e['type']=='summary')['quotes']==[]
# Validate the ambiguity union, including the ban on a selected primary citation.
candidate={'surah':1,'ayah_from':1,'ayah_to':1,'word_from':0,'word_to':4,'confidence':0.5,'text_uthmani':'sample','reference':'Al-Fatiha 1:1'}
quote={'type':'quote_detected','surah':None,'ayah_from':None,'ayah_to':None,'word_from':None,'word_to':None,'start_seconds':1,'end_seconds':3,'confidence':0.5,'text_uthmani':None,'reference':None,'verified':False,'ambiguous':True,'candidates':[candidate,{**candidate,'surah':27,'ayah_from':30,'ayah_to':30,'reference':'An-Naml 27:30'}]}
validator.validate(quote)
bad={**quote,'surah':1}
assert list(validator.iter_errors(bad)),'ambiguous primary citation must be rejected by the schema'
print('SPOT CLI / MODEL-FREE TEXT / STDIO / JSON SCHEMA PASS')

# Example integration preserves prose and never promotes unverified candidates.
import importlib.util
spec=importlib.util.spec_from_file_location('splice',root/'examples/python-lecture/splice.py');module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
words=[{'start':0,'end':1,'text':'Before'},{'start':1,'end':2,'text':'garbled'},{'start':2,'end':3,'text':'ASR'},{'start':3,'end':4,'text':'after'}]
quote={'verified':True,'ambiguous':False,'start_seconds':1,'end_seconds':3,'text_uthmani':'sample','reference':'reference'}
proposals=module.propose_replacements(words,[quote]);assert len(proposals)==1 and proposals[0]['word_from']==1 and proposals[0]['word_to']==3 and proposals[0]['requires_review']
assert module.propose_replacements(words,[{**quote,'verified':False}])==[]
assert words[0]['text']=='Before' and words[3]['text']=='after'
print('REVIEW-ONLY TRANSCRIPT REPLACEMENT EXAMPLE PASS')
