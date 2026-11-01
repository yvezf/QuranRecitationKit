// Microphone transport uses the universal sidecar; the native Node API also accepts your own PCM.
const {spawn}=require('node:child_process');const readline=require('node:readline');
const executable=process.env.QRK_BINARY||'qrk';const extra=process.env.QRK_MODEL_DIR?['--model',process.env.QRK_MODEL_DIR]:[];
const child=spawn(executable,['mic','--surah',process.argv[2]||'1','--json',...extra,...(process.env.QRK_MIC_SECONDS?['--seconds',process.env.QRK_MIC_SECONDS]:[])],{stdio:['pipe','pipe','inherit']});
readline.createInterface({input:child.stdout}).on('line',line=>{const event=JSON.parse(line);console.log(event);});
process.on('SIGINT',()=>child.stdin.write('{"type":"stop"}\n'));child.on('error',error=>{console.error(error.message);process.exitCode=2;});child.on('exit',code=>{process.exitCode=code??2;});
