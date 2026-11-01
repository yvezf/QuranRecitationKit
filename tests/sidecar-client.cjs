const {spawn}=require('node:child_process');const assert=require('node:assert/strict');
const WebSocket=require('../bindings/node/node_modules/ws');
const binary=process.env.QRK_BINARY||'core/target/debug/qrk';
const helper=spawn(binary,['serve','--port','0','--token','local-test-token','--model',process.env.QRK_MODEL_DIR],{stdio:['ignore','pipe','pipe']});
let started=false;let stderr='';const timeout=setTimeout(()=>{helper.kill();throw new Error('sidecar timeout '+stderr)},20000);
helper.stderr.on('data',chunk=>{stderr+=chunk;if(started)return;const match=stderr.match(/Listening (127\.0\.0\.1:\d+)/);if(!match)return;started=true;
 const ws=new WebSocket('ws://'+match[1],{headers:{Authorization:'Bearer local-test-token'}});const events=[];
 ws.on('open',()=>ws.send(JSON.stringify({type:'start',target:{surah:112},format:'f32le',sample_rate:16000})));
 ws.on('message',data=>{const event=JSON.parse(data);events.push(event);console.log(JSON.stringify(event));if(event.type==='state'&&event.state==='listening'){ws.send(Buffer.alloc(16000*4));ws.send(JSON.stringify({type:'stop'}));}
  if(event.type==='summary'){assert.equal(event.verses.length,0);assert(events.some(e=>e.type==='needs_retry'&&e.reason==='noise'));ws.close();helper.kill();clearTimeout(timeout);console.log('SIDECAR PASS');}
 });ws.on('error',error=>{clearTimeout(timeout);helper.kill();throw error;});
});helper.on('error',error=>{clearTimeout(timeout);throw error;});
