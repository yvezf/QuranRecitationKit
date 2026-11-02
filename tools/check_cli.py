#!/usr/bin/env python3
"""CLI contract checks, including isolated Linux no-input behavior. No mic capture."""
from pathlib import Path
import json,os,subprocess,sys,tempfile
root=Path(__file__).resolve().parent.parent
binary=root/'core/target/release'/('qrk.exe'if os.name=='nt'else'qrk')
help_text=subprocess.check_output([str(binary),'--help'],text=True)
for phrase in ['pinned offline model','usable microphone','WAV file','microphone audio','WebSocket','tokenizer']:
    assert phrase in help_text,phrase
fetch_help=subprocess.check_output([str(binary),'model','fetch','--help'],text=True)
assert 'SHA-256' in fetch_help
# Isolate the ALSA config for these child processes; never change host settings.
if sys.platform.startswith('linux'):
    with tempfile.TemporaryDirectory(prefix='qrk-no-input-') as temporary:
        config=Path(temporary)/'alsa.conf';config.write_text('')
        env=dict(os.environ,ALSA_CONFIG_PATH=str(config))
        for args in [['devices'],['mic','--surah','78','--seconds','1'],['spot','--mic','--seconds','1']]:
            result=subprocess.run([str(binary),*args],capture_output=True,text=True,env=env,timeout=30)
            assert result.returncode!=0,(args,result.stdout,result.stderr)
            lines=result.stderr.strip().splitlines()
            assert len(lines)==1 and lines[0].startswith('qrk: '),(args,lines)
            assert 'ALSA lib'not in result.stderr
            assert not result.stdout,(args,result.stdout)
            print(json.dumps({'command':args[0],'status':'passed','exit_code':result.returncode,'stderr':lines[0]}))
print('CLI HELP / NO-INPUT CONTRACT PASS')
