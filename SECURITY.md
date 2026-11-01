# Security

Recognition processes audio locally. The engine has no telemetry or account. Optional network surfaces are explicit HTTPS model download and an explicitly started localhost sidecar; no microphone audio is uploaded by the SDK.

Model files are checked against a pinned byte count and SHA-256, independently of the supplied manifest. A filename alone never establishes compatibility. Runtime corpus caches are local to the user and keyed by source/tokenizer/index version. Do not distribute a generated normalized corpus index. Release helpers can embed ONNX Runtime and materialize its verified bytes in the application's local cache.

The sidecar binds 127.0.0.1, limits message size and concurrent sessions, and supports an Authorization bearer token. Web applications must use an app-controlled helper and token; do not expose it to remote networks. Only trusted application code should call the C ABI or configure model/corpus/runtime paths. C callers own buffer lifetime and must not free an in-use handle. Native callbacks borrow strings only until returning.

Audio capture is opt-in and subject to OS permissions. Transport errors, overruns, inconclusive audio, and calibration limits must be represented honestly by hosts. Recognition confidence is not a security credential or a calibrated pronunciation judgement.

Report vulnerabilities privately using the published repository's Security advisory page. No response deadline or external support contact is promised before that repository exists.
