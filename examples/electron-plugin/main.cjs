// Use from Electron's main process, not an untrusted renderer.
const {spawn}=require('node:child_process');
const {Sidecar}=require('../../bindings/node');
const token=require('node:crypto').randomBytes(24).toString('hex');
const helper=spawn(process.env.QRK_BINARY||'qrk',['serve','--token',token,'--model',process.env.QRK_MODEL_DIR],{stdio:['ignore','ignore','pipe']});
helper.stderr.on('data',data=>{if(data.toString().includes('Listening')){
 const client=new Sidecar({token});client.on('event',console.log);client.on('error',console.error);
 client.on('open',()=>client.start({surah:112}));
 // Forward a trusted PCM source with client.feed(Float32Array); then client.stop().
}});
process.on('exit',()=>helper.kill());
