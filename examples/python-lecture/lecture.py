#!/usr/bin/env python3
"""WAV -> reviewable citations, using the packaged qrk helper; standard library only."""
import argparse,json,subprocess
p=argparse.ArgumentParser();p.add_argument('wav');p.add_argument('--qrk',default='qrk');p.add_argument('--model');p.add_argument('--json',action='store_true');a=p.parse_args()
command=[a.qrk]+(['--model',a.model] if a.model else [])+['spot','--wav',a.wav,'--json']
with subprocess.Popen(command,stdout=subprocess.PIPE,text=True,encoding='utf-8') as process:
    for line in process.stdout:
        event=json.loads(line)
        if event['type']!='quote_detected':continue
        if a.json:print(json.dumps(event,ensure_ascii=False))
        elif event['verified'] and not event['ambiguous']:
            print(f"{event['start_seconds']:.2f}–{event['end_seconds']:.2f}s  {event['reference']}\n{event['text_uthmani']}\n")
        else:print('Needs review: '+', '.join(c['reference'] for c in event['candidates']))
    status=process.wait()
    if status:raise SystemExit(status)
