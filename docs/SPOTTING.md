# Quran quotations in transcription apps

Spot mode finds candidate Qur'an quotations without an expected passage. Feed the **same audio clock** to your transcriber and to a separate spotter. The transcriber handles lecture prose; the spotter supplies timestamped citations and verbatim Arabic. Neither a transcript-only match nor an ambiguous result authorizes replacement. The host decides what to insert.

## Start with a recording

Download the platform CLI archive from the SDK release, extract it, then:

```sh
./qrk model fetch
./qrk spot --wav lecture.wav --json
```

Windows: use `.\qrk.exe`. WAV input accepts supported PCM/Float32 WAV, downmixes by the channel mean and resamples. `qrk spot --mic --json` explicitly starts microphone capture; `--device NAME` and `--seconds 30` are optional. Permission belongs to the host OS. Dropped capture chunks are reported; treat their results as incomplete. No microphone is started merely by loading the library or matching text.

A detected quote contains:

```json
{
  "type": "quote_detected",
  "surah": 78,
  "ayah_from": 2,
  "ayah_to": 2,
  "word_from": 0,
  "word_to": 3,
  "start_seconds": 10.089,
  "end_seconds": 13.099,
  "confidence": 0.586,
  "text_uthmani": "عَنِ ٱلنَّبَإِ ٱلْعَظِيمِ",
  "reference": "An-Naba 78:2",
  "verified": true,
  "ambiguous": false,
  "candidates": []
}
```

These rounded example times come from a local owned recording embedded after four seconds of noise; they are not a classroom accuracy claim. `word_from` and `word_to` are zero-based half-open offsets, in the first and last ayah respectively. Partial quotations retain their word range. Multi-ayah display text joins unchanged source slices with a newline. Each slice preserves Tanzil's original Arabic bytes, whitespace and marks; it is never the normalized recognition string.

`start_seconds` and `end_seconds` are relative to the first PCM sample supplied after construction/reset. They come from CTC frame alignment and are approximate, not sample-accurate cuts. Preserve that clock when mapping to ASR word timestamps. For audio extracted from a later part of a lecture, add the extraction offset yourself. Overlapping windows are merged; a 1.2-second silence or sustained verification failure closes a quote. A natural pause longer than this can produce separate citations for successive ayahs.

## Ambiguity is explicit

The basmala can refer to 1:1 or a span of 27:30. Repeated ayahs and common phrases can have several valid locations. Ambiguous audio events have **`verified:false`, `ambiguous:true`, confidence at most 0.5, and null primary citation/text fields**. Their `candidates` carry the alternatives. There is no leading citation for an application to insert accidentally. Later, stronger context can resolve a still-open suggestion before it is emitted.

`verified:true` means the machine's acoustic/lexical gates passed, **not** a human-confirmed verdict or calibrated probability. Keep a review path, especially before replacing lecture words. The spotter does not identify the speaker or distinguish deliberate recitation from prose that happens to quote the same Arabic words.

## Match an existing transcript, without weights

```sh
./qrk match-text 'عم يتساءلون عن النبإ العظيم' --json
```

This does not load/download an acoustic model. Every result is `verified:false`, including a unique candidate. Short phrases such as `الذين آمنوا` return alternatives rather than a verdict. If the corresponding PCM is available, feed that segment to a spotter for separate acoustic verification; map its relative times back to the lecture clock. Do not promote a text-only candidate merely because its text looks exact.

## Bindings

Python, from an installed release wheel:

```python
from quranrecitationkit import Spotter, model_fetch, match_text
spot = Spotter(model_fetch(), on_event=print)
spot.feed(pcm16k)  # finite mono Float32 samples; await/control producer throughput
summary = spot.stop()
print(summary['quotes'])
suggestions = match_text('الذين آمنوا')  # always verified=False
```

Node, from the release's native prebuild and source facade:

```js
const {Spotter, matchText} = require('@quranrecitationkit/node');
const spot = new Spotter({modelDir: modelDirectory});
spot.on('quote_detected', quote => console.log(quote));
await spot.feed(pcm16k); // Float32Array; await each feed for backpressure
const summary = await spot.stop();
const suggestions = await matchText('الذين آمنوا');
```

Swift, from the checksum-pinned SwiftPM package:

```swift
let model = try await ModelPack.download()
let spot = try await RecitationSpotter(modelPack: model)
let reader = Task {
    for await event in spot.events {
        if case .quoteDetected(let quote) = event { print(quote) }
    }
}
try await spot.feed(pcm16k)
let summary = try await spot.stop()
let suggestions = try await RecitationSpotter.matchText("الذين آمنوا")
reader.cancel()
```

`SpotEvent` is separate from `RecitationEvent`, preserving existing tracking switches. The optional `RecitationMicrophone.start` adapter accepts an async chunk closure; it can feed either mode. Hosts own capture, buffering, error handling and the application's audio-session policy.

.NET:

```csharp
using var spot = new RecitationSpotter(modelDirectory);
spot.Event += e => Console.WriteLine(e.GetRawText());
spot.Feed(pcm16k); // float[], 16 kHz mono; use a worker in GUI applications
var summary = spot.Stop();
var suggestions = QuotationMatcher.MatchText("الذين آمنوا");
```

Rust: `qrk_onnx::Recognizer::new_spotting(model, corpus, SpotConfig::default())` returns an independent `Spotter`. Its `feed`/`stop` return quotation events/summary; `reset` resets the clock. `qrk_onnx::match_text` is model-free. The pure `qrk_core::Spotter<M>` accepts a custom acoustic runner for deterministic tests. C exposes `qrk_spotter_new/feed/stop/reset/free` and `qrk_match_text`; returned JSON is freed with `qrk_string_free`. A spotter handle must never be passed to tracking-handle functions. Callbacks borrow their strings only for the call and handles remain live until the call finishes.

## Sidecar and examples

Start `qrk serve --stdio` or the localhost WebSocket helper. No target is needed:

```json
{"type":"start","mode":"spot","format":"f32le","sample_rate":16000}
{"type":"audio","data":"BASE64_PCM"}
{"type":"stop"}
```

`{"type":"match_text","text":"الذين آمنوا"}` works before an audio session and returns `type:text_match, verified:false`. WebSocket audio remains binary; stdio audio is base64. Supported sample rates are 16/44.1/48 kHz. A summary contains `quotes:[]` alongside the existing fields. Use independent sessions to track a known passage and spot open-set quotes from the same PCM.

[Python lecture example](../examples/python-lecture/README.md) runs a WAV through the standalone CLI and prints reviewable citations. It includes an opt-in, word-timestamp transcript-splicing helper. [Node notes example](../examples/node-notes/README.md) reads live citations from the microphone CLI. Neither needs an npm/PyPI registry publication. Hosts that already capture PCM should use the native bindings instead of recording a second microphone stream.

## Gates, configuration and limits

The default uses an 8-second ring, one model forward per second, top eight retrieved candidates, the tracking margin of at least 0.035, at least three distinct words and at least 1.5 seconds. The window is configurable from 6–12 seconds. Complete short ayahs can pass at the higher 0.20 margin; exact single-word ayahs also compare competing occurrences. Short incomplete audio phrases are ignored; transcript matching can still suggest candidates for them. Increasing a gate can reduce recall. These values are support heuristics, not calibrated confidence percentages.

Word trigrams retrieve the shortlist, with bigrams as fallback, then the CTC scorer checks the aligned span and its ayah-boundary extensions. Existing pronunciation token variants are admitted; output remains original Tanzil. Normalized postings are built at runtime and cached only in the user's cache directory, validated against the corpus on reuse. No generated Quran index, recording or acoustic model is shipped in Git/SDK packages.

The local gates cover synthetic timed logits, the owner's two clips in a seeded noisy carrier, non-speech, and local synthetic English/Arabic prose/common phrases. **Precision/recall on actual classroom lectures is unmeasured.** Distance, reverb, interruptions, code-switching, fast speech and ASR spelling errors can reduce recall or produce suggestions requiring correction. This Arabic-only acoustic model does not provide English transcription or language identification; English is not a retrieval language, but no zero-false-positive guarantee on arbitrary audio is claimed. A noisy carrier is not a substitute for real classroom evaluation. There is no Tajweed assessment or judgment of the reciter.

Display **Tanzil** as the source, link to [tanzil.net](https://tanzil.net), and reproduce the [Tanzil notice](../corpus/TANZIL-NOTICE.txt) when displaying/distributing `text_uthmani`. See [THIRD_PARTY_NOTICES](../THIRD_PARTY_NOTICES.md).
