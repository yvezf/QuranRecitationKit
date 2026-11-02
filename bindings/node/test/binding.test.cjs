const {test}=require('node:test');const assert=require('node:assert/strict');const {Recognizer,version}=require('..');
test('native version',()=>assert.equal(version(),'0.2.0'));
test('requires an explicit model pack',()=>assert.throws(()=>new Recognizer(),/modelDir/));
test('rejects missing model',()=>assert.throws(()=>new Recognizer({modelDir:'/not-a-model-pack'})));
test('real model optional smoke',{skip:!process.env.QRK_MODEL_DIR},async()=>{const r=new Recognizer({modelDir:process.env.QRK_MODEL_DIR});const events=[];r.on('event',e=>events.push(e));await r.setExpected({surah:112});await r.feed(new Float32Array(8000));const summary=await r.stop();assert.equal(summary.verses.length,0);assert(events.some(e=>e.type==='needs_retry'));await r.reset();});
