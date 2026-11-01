import {EventEmitter} from 'node:events';
export type Target={surah:number}|{surah:number,from:number,to:number}|{surah:number,ayah:number,from:number,to:number};
export interface Event{type:'word_progress'|'verse_match'|'needs_retry'|'raw_transcript'|'state';[key:string]:unknown}
export interface Summary{verses:Array<{surah:number,ayah:number,confidence:number,duration_seconds:number}>;transcript:string;duration:number;events:Event[]}
export class Recognizer extends EventEmitter{
 constructor(options:{modelDir:string,corpusPath?:string,configuration?:{live_tracking?:boolean,maximum_window_seconds?:number,backtrack_words?:number,lookahead_words?:number,policy?:'balanced'|'conservative'|'lenient'}});
 setExpected(target:Target):Promise<void>;feed(pcm:Float32Array):Promise<Event[]>;stop():Promise<Summary>;reset():Promise<void>;
}
export class Sidecar extends EventEmitter{constructor(options?:{url?:string,token?:string});start(target:Target,options?:{format?:'f32le'|'s16le',sampleRate?:number}):void;feed(pcm:Float32Array):void;stop():void;close():void}
export function version():string;
