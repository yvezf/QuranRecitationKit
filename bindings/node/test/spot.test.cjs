const {test}=require('node:test');const assert=require('node:assert/strict');

test('model-free quotations remain unverified and preserve ambiguity',async()=>{
 const {matchText}=require('..');const result=await matchText('الذين آمنوا');assert.equal(result.verified,false);assert.equal(result.ambiguous,true);assert(result.candidates.length>=2);assert(result.candidates.every(c=>c.confidence<=0.5));
 const unique=await matchText('عم يتساءلون عن النبإ العظيم');assert(unique.candidates.some(c=>c.surah===78&&c.ayah_from===1&&c.ayah_to===2));
 const english=await matchText('The teacher explains the timetable');assert.equal(english.candidates.length,0);
});
test('spotter requires a real model',()=>{const {Spotter}=require('..');assert.throws(()=>new Spotter({modelDir:'/not-a-model-pack'}));});
test('spotter silence has no quotations',{skip:!process.env.QRK_MODEL_DIR},async()=>{const {Spotter}=require('..');const r=new Spotter({modelDir:process.env.QRK_MODEL_DIR});await r.feed(new Float32Array(32000));const summary=await r.stop();assert.equal(summary.quotes.length,0);await r.reset();});
