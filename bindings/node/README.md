# @quranrecitationkit/node

Native offline recognition plus an optional localhost sidecar client. Node 18+; platform prebuilds are produced by the release workflow, not claimed to be published before review. Build locally with `npm ci && npm run build` (Rust stable required).

```js
const {Recognizer}=require('@quranrecitationkit/node');
const r=new Recognizer({modelDir:'/path/to/model'});
r.on('event',event=>console.log(event));
await r.setExpected({surah:112});
await r.feed(pcmFloat32); // Float32Array, mono 16000 Hz
const summary=await r.stop();
await r.reset();
```

Await feed calls: the binding copies your PCM, runs inference on a native worker, and serializes commands. A 64-command backpressure limit rejects flooding instead of accumulating unlimited audio. Events are `word_progress`, `verse_match`, `needs_retry`, `raw_transcript`, and `state`; `summary.events` contains final events, also emitted before stop resolves.

Only a verified model pack is accepted. Set `ORT_DYLIB_PATH` for a development runtime or build with the runtime embedded. The root release workflow provides platform builds. The helper/mic example is `examples/node-mic`; applications with their own capture can feed the native binding directly. See `protocol/SIDECAR.md` for `Sidecar` and transport security.

No translation, recitation recording, generated normalized Quran index or model weights are shipped in this npm package. Carry the project/native dependency notices with redistribution.

## GitHub release installation

No npm registry upload has been performed. Clone https://github.com/yvezfscarves-afk/QuranRecitationKit, download the matching `node-<platform>.zip` from https://github.com/yvezfscarves-afk/QuranRecitationKit/releases/tag/v0.1.0, and extract it into `bindings/node` so its `prebuilds/<platform>-<arch>/qrk.node` is present. In your host project run `npm install /path/to/QuranRecitationKit/bindings/node`. The package includes the selected native runtime and notices; no Rust build is needed when the matching prebuild exists.
