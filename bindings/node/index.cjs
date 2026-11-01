'use strict';
const {EventEmitter}=require('node:events');const fs=require('node:fs');const path=require('node:path');
const directory=path.join(__dirname,'prebuilds',`${process.platform}-${process.arch}`);
const runtime=path.join(directory,process.platform==='win32'?'onnxruntime.dll':process.platform==='darwin'?'libonnxruntime.dylib':'libonnxruntime.so');
if(!process.env.ORT_DYLIB_PATH&&fs.existsSync(runtime))process.env.ORT_DYLIB_PATH=runtime;
let addon;function native(){return addon||(addon=require(path.join(directory,'qrk.node')));}
class Recognizer extends EventEmitter{
 constructor({modelDir,corpusPath,configuration}={}){super();if(typeof modelDir!=='string')throw new TypeError('modelDir is required');this._native=new(native().NativeRecognizer)(modelDir,corpusPath,configuration?JSON.stringify(configuration):undefined);this._chain=Promise.resolve();this._queued=0;}
 _enqueue(operation){if(this._queued>=64)return Promise.reject(new Error('Backpressure: await feed() before supplying more audio'));this._queued++;const run=this._chain.then(operation);this._chain=run.catch(()=>{}).finally(()=>this._queued--);return run;}
 _emit(events){for(const event of events){this.emit('event',event);this.emit(event.type,event);}}
 setExpected(target){return this._enqueue(()=>this._native.setExpected(JSON.stringify(target)));}
 feed(pcm){if(!(pcm instanceof Float32Array))return Promise.reject(new TypeError('feed requires a Float32Array at 16000 Hz mono'));const copy=new Float32Array(pcm);return this._enqueue(async()=>{const events=JSON.parse(await this._native.feed(copy));this._emit(events);return events;});}
 stop(){return this._enqueue(async()=>{const summary=JSON.parse(await this._native.stop());this._emit(summary.events);return summary;});}
 reset(){return this._enqueue(()=>this._native.reset());}
}
function version(){return native().version();}
class Sidecar extends EventEmitter{
 constructor({url='ws://127.0.0.1:7877',token}={}){super();const WS=require('ws');this.socket=new WS(url,token?{headers:{Authorization:`Bearer ${token}`}}:{});this.socket.on('open',()=>this.emit('open'));this.socket.on('message',data=>{const event=JSON.parse(data.toString());this.emit('event',event);if(event.type!=='error'||this.listenerCount('error'))this.emit(event.type,event);});this.socket.on('error',error=>this.emit('error',error));this.socket.on('close',()=>this.emit('close'));}
 start(target,{format='f32le',sampleRate=16000}={}){this.socket.send(JSON.stringify({type:'start',target,format,sample_rate:sampleRate}));}
 feed(pcm){if(!(pcm instanceof Float32Array))throw new TypeError('PCM must be Float32Array');this.socket.send(Buffer.from(pcm.buffer,pcm.byteOffset,pcm.byteLength));}
 stop(){this.socket.send(JSON.stringify({type:'stop'}));}
 close(){this.socket.close();}
}
module.exports={Recognizer,Sidecar,version};
