"""python main.py --model MODEL_DIRECTORY --surah 112 FILE.wav
WAV must be PCM16, mono, 16 kHz; use qrk wav for automatic resampling.
"""
import argparse, json, struct, wave
from quranrecitationkit import Recognizer
p=argparse.ArgumentParser(); p.add_argument('--model',required=True); p.add_argument('--surah',type=int,required=True);p.add_argument('wav');a=p.parse_args()
r=Recognizer(a.model,on_event=lambda event: print(json.dumps(event,ensure_ascii=False)))
r.set_expected({'surah':a.surah})
with wave.open(a.wav,'rb')as w:
    if (w.getnchannels(),w.getsampwidth(),w.getframerate())!=(1,2,16000):raise ValueError('expected mono PCM16 16 kHz')
    while data:=w.readframes(4800):r.feed([x/32768 for x in struct.unpack('<'+'h'*(len(data)//2),data)])
print(json.dumps(r.stop(),ensure_ascii=False))
