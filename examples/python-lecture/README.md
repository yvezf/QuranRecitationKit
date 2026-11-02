# WAV to citations, without a Python native install

Extract the platform SDK CLI ZIP, run `qrk model fetch`, then:

```sh
python3 lecture.py lecture.wav --qrk /path/to/qrk
```

On Windows use `py lecture.py lecture.wav --qrk C:\path\qrk.exe`. `--model DIR` selects an already verified model directory; `--json` prints the quotation events unchanged. Only the standard Python library is required. Recognition stays local; the supplied WAV is not uploaded or copied by this example. The CLI's one-time model download is separate.

For a GUI app already feeding PCM to its own transcriber, use the native Python `Spotter` instead; see [the integration guide](../../docs/SPOTTING.md). Feed matching clocks. `splice.py` demonstrates reviewable replacement proposals using ASR **word** timestamps, preserving prose outside the matched words. It never inserts ambiguous or unverified candidates and never modifies a transcript itself. Keep the original transcript and let the user accept a proposal. Display Tanzil attribution/link and carry the notice.
