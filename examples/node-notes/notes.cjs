'use strict';
// Explicit microphone opt-in, via the universal helper; no npm packages required.
const {spawn}=require('node:child_process');const {createInterface}=require('node:readline');
if(!process.argv.includes('--mic')){console.error('Use: node notes.cjs --mic [--qrk /path/to/qrk]');process.exit(2);}
const index=process.argv.indexOf('--qrk');const binary=index>=0?process.argv[index+1]:'qrk';
if(!binary){console.error('--qrk requires a path');process.exit(2);}
const child=spawn(binary,['spot','--mic','--json'],{stdio:['pipe','pipe','inherit']});
child.on('error',e=>{console.error(e.message);process.exitCode=1;});
createInterface({input:child.stdout}).on('line',line=>{
 try{const event=JSON.parse(line);if(event.type==='quote_detected'){
  if(event.verified&&!event.ambiguous)console.log(JSON.stringify({kind:'citation_suggestion',start:event.start_seconds,end:event.end_seconds,text:event.text_uthmani,reference:event.reference,requiresReview:true}));
  else console.log(JSON.stringify({kind:'citation_candidates',candidates:event.candidates,requiresReview:true}));
 }}catch(e){console.error('Invalid helper output:',e.message);process.exitCode=1;child.kill();}
});
process.on('SIGINT',()=>{if(child.stdin.writable)child.stdin.end('{"type":"stop"}\n');});
child.on('exit',code=>{if(code)process.exitCode=code;});
