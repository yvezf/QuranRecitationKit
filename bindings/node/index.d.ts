import {EventEmitter} from 'node:events';
export type Target={surah:number}|{surah:number,from:number,to:number}|{surah:number,ayah:number,from:number,to:number};
export interface QuoteCandidate {surah:number;ayah_from:number;ayah_to:number;word_from:number;word_to:number;confidence:number;text_uthmani:string;reference:string}
export interface Quote {surah:number|null;ayah_from:number|null;ayah_to:number|null;word_from:number|null;word_to:number|null;start_seconds:number;end_seconds:number;confidence:number;text_uthmani:string|null;reference:string|null;verified:boolean;ambiguous:boolean;candidates:QuoteCandidate[]}
export interface QuoteDetected extends Quote {type:'quote_detected'}
export interface TrackingEvent {type:'word_progress'|'verse_match'|'needs_retry'|'raw_transcript'|'state';[key:string]:unknown}
export type Event=TrackingEvent|QuoteDetected;
export interface Summary{verses:Array<{surah:number,ayah:number,confidence:number,duration_seconds:number}>;quotes:Quote[];transcript:string;duration:number;events:Event[]}
export interface TextMatch {verified:false;ambiguous:boolean;candidates:QuoteCandidate[]}
export interface SpotConfiguration {window_seconds?:number;min_words?:number;min_seconds?:number;min_margin?:number;high_margin?:number;ambiguity_margin?:number;max_candidates?:number}
export class Recognizer extends EventEmitter{
 constructor(options:{modelDir:string,corpusPath?:string,configuration?:{live_tracking?:boolean,maximum_window_seconds?:number,backtrack_words?:number,lookahead_words?:number,policy?:'balanced'|'conservative'|'lenient'}});
 setExpected(target:Target):Promise<void>;feed(pcm:Float32Array):Promise<Event[]>;stop():Promise<Summary>;reset():Promise<void>;
}
export class Spotter extends EventEmitter {
 constructor(options:{modelDir:string;corpusPath?:string;configuration?:SpotConfiguration});
 feed(pcm:Float32Array):Promise<Event[]>;stop():Promise<Summary>;reset():Promise<void>;matchText(text:string):Promise<TextMatch>;
}
export function matchText(text:string):Promise<TextMatch>;
export interface StreamFormat {format?:'f32le'|'s16le';sampleRate?:number}
export class Sidecar extends EventEmitter {constructor(options?:{url?:string,token?:string});start(target:Target,options?:StreamFormat):void;startSpot(options?:StreamFormat&{configuration?:SpotConfiguration}):void;matchText(text:string):void;feed(pcm:Float32Array|Int16Array):void;stop():void;close():void}
export function version():string;
