# Live citation suggestions in notes

Extract the platform CLI ZIP, run `qrk model fetch`, then:

```sh
node notes.cjs --mic --qrk /path/to/qrk
```

Windows can pass the path to `qrk.exe`. No npm dependency is needed. Microphone permission is explicit; Ctrl-C sends a stop command and allows the helper to flush. Capture failures/drops go to stderr. Output is a reviewable note/candidate suggestion, not an automatic transcript replacement. Display Tanzil attribution and retain the original ASR words.

If your app already has PCM for Whisper/another transcriber, **do not start a second capture**. Feed the same 16 kHz mono `Float32Array` to the native `Spotter` and map its events to your own word timestamps. See [the integration guide](../../docs/SPOTTING.md) for native Node and WebSocket alternatives, ambiguity handling and measured limits.
