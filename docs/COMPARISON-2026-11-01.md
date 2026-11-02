# Comparison verification — 2026-11-01

These notes support the README's dated comparison. They compare the integration contract, declared platforms and published licensing statements, not recognition accuracy, latency or commercial success. A declared platform is not an independent runtime test. A model card's license label does not establish every intermediate export's provenance. Missing evidence is marked **unverified**, including for this project.

## QuranRecitationKit

| Cell | Evidence and qualification |
|---|---|
| Integrates from | [C ABI](../core/qrk-ffi/include/qrk.h), [stdio/WebSocket protocol](../protocol/SIDECAR.md), and the [Swift](../bindings/swift/README.md), [Node](../bindings/node/README.md), [Python](../bindings/python/README.md) and [.NET](../bindings/dotnet/README.md) bindings. A host needs C interoperability or the ability to spawn/connect to the sidecar; no browser/WASM SDK is claimed. |
| Platforms | [CI](../.github/workflows/ci.yml) and the [green source run](https://github.com/yvezf/QuranRecitationKit/actions/runs/41356408185) cover Windows x64, Linux x64, macOS arm64/x64 and the Swift/iOS build. [Package.swift](../Package.swift) declares iOS 16 and macOS 14. [Publication receipt](PUBLICATION-2026-11-01.md) distinguishes native desktop inference from an iOS build; this is not an iPhone performance benchmark. |
| Code license | [LICENSE](../LICENSE) is MIT; [third-party notices](../THIRD_PARTY_NOTICES.md) preserve dependency and Tilawa attribution. |
| Model/data license | [NVIDIA model card](https://huggingface.co/nvidia/stt_ar_fastconformer_hybrid_large_pcd_v1.0) states CC BY 4.0. [Tanzil's notice](https://tanzil.net/docs/text_license) states CC BY 3.0 with additional verbatim-text/attribution/link conditions. [Our notices §2](../THIRD_PARTY_NOTICES.md#2-nvidia-acoustic-weights-vocabulary-and-tokenizer) retain the historical v1 qualification. [Model-v2](../MODEL_CARD.md) is now a verified direct NVIDIA/NeMo export, with licensed preprocessing and separately published source/native/local validation receipts. |

The README names the actual licenses and Tanzil’s explicit text conditions rather than making an unqualified blanket claim. The v1 intermediate-export warning is historical; v2 is reproduced from the pinned NVIDIA checkpoint through licensed tools. “Every platform” is scoped by the explicit platform list; it does not add Android or browser runtime support.

## Tilawa

Checked source: [`2f2617460dc4a6b967e0cc49fa04804bbf22ec69`](https://github.com/yazinsai/tilawa/tree/2f2617460dc4a6b967e0cc49fa04804bbf22ec69).

| Cell | Evidence and qualification |
|---|---|
| Integrates from | [README install instructions](https://github.com/yazinsai/tilawa/blob/2f2617460dc4a6b967e0cc49fa04804bbf22ec69/README.md) publish `@tilawa/core` as TypeScript and list runtime adapters for web, Node and React Native. |
| Platforms | The same README names those three runtime families. This comparison does not claim an independent native OS test matrix for Tilawa. |
| Code license | [LICENSE](https://github.com/yazinsai/tilawa/blob/2f2617460dc4a6b967e0cc49fa04804bbf22ec69/LICENSE) is MIT. |
| Model/data license | [README](https://github.com/yazinsai/tilawa/blob/2f2617460dc4a6b967e0cc49fa04804bbf22ec69/README.md) names Zipformer as the default and retains the FastConformer API. [NOTICE](https://github.com/yazinsai/tilawa/blob/2f2617460dc4a6b967e0cc49fa04804bbf22ec69/NOTICE.md) separates MIT code from NPL-1.2 Zipformer weights, vocabulary and phoneme corpus; it describes no paid features and share-alike derivatives. FastConformer assets are identified as NVIDIA CC BY 4.0. This is a statement of their published terms, not a certification of every export in that path. |

The ancestry sentence in our README expressly credits Tilawa's normalizer, decoder and aligner. A dated comparison is not a claim that those algorithms originated here.

## recite_quran

Checked published package: [1.0.5](https://pub.dev/packages/recite_quran/versions/1.0.5), with [pub.dev metadata](https://pub.dev/api/packages/recite_quran).

| Cell | Evidence and qualification |
|---|---|
| Integrates from | The [package page](https://pub.dev/packages/recite_quran) and published manifest show a Flutter SDK dependency and a Dart API. Its native inference dependency does not turn the published package into a documented C/Swift/Node SDK. |
| Platforms | pub.dev lists Android, iOS, Linux, macOS, web and Windows; the published manifest declares the same six. These are publisher declarations, not independent test results. |
| Code license | The [published license](https://pub.dev/packages/recite_quran/license) imposes a custom Sacred Covenant, including free-to-end-users and noncommercial restrictions. pub.dev's machine-readable classification is unknown. It is not labeled MIT in our comparison. |
| Model/data license | The package README links [Quran-Lab/zipformer_p-arabic-v3](https://huggingface.co/Quran-Lab/zipformer_p-arabic-v3); that model page declares NPL-1.2. Its gated model files were not requested or downloaded. The licenses/provenance of other package data were not established, so those remain unverified. |

## QuranRecognitionKit

Checked source: [`81b769ab52a054f773d1c0127f57315fdf02350c`](https://github.com/akhandafm17/QuranRecognitionKit/tree/81b769ab52a054f773d1c0127f57315fdf02350c).

| Cell | Evidence and qualification |
|---|---|
| Integrates from | [README](https://github.com/akhandafm17/QuranRecognitionKit/blob/81b769ab52a054f773d1c0127f57315fdf02350c/README.md) and [Package.swift](https://github.com/akhandafm17/QuranRecognitionKit/blob/81b769ab52a054f773d1c0127f57315fdf02350c/Package.swift) publish a Swift package. |
| Platforms | The current manifest declares both iOS 17+ and macOS 14+. The supplied comparison draft omitted macOS, so the README corrects that. Neither platform was independently built in this audit. |
| Code license | [LICENSE](https://github.com/akhandafm17/QuranRecognitionKit/blob/81b769ab52a054f773d1c0127f57315fdf02350c/LICENSE) is MIT. |
| Model/data license | [MODEL_NOTICE](https://github.com/akhandafm17/QuranRecognitionKit/blob/81b769ab52a054f773d1c0127f57315fdf02350c/MODEL_NOTICE.md) identifies NVIDIA's FastConformer and its CC BY 4.0 model card. This verifies the stated model attribution, not every export step. A separate license for the bundled Qur'an text was not established and remains unverified. No weights or recitation test data were downloaded. |

## Real-Time Quran recitation tracker

Checked source: [`b22c2adb617bf5df982ca2492624fdef780c4913`](https://github.com/yayaiu6/Real-Time-Quran-recitation-tracker-System/tree/b22c2adb617bf5df982ca2492624fdef780c4913).

| Cell | Evidence and qualification |
|---|---|
| Integrates from | [README](https://github.com/yayaiu6/Real-Time-Quran-recitation-tracker-System/blob/b22c2adb617bf5df982ca2492624fdef780c4913/README.md), [requirements](https://github.com/yayaiu6/Real-Time-Quran-recitation-tracker-System/blob/b22c2adb617bf5df982ca2492624fdef780c4913/requirements.txt) and [run.py](https://github.com/yayaiu6/Real-Time-Quran-recitation-tracker-System/blob/b22c2adb617bf5df982ca2492624fdef780c4913/run.py) establish a Python Flask/Socket.IO server with a browser frontend. |
| Platforms | Server/browser architecture is verified; a maintained native OS support matrix was not established. The comparison therefore marks specific OS support unverified. |
| Code license | [LICENSE](https://github.com/yayaiu6/Real-Time-Quran-recitation-tracker-System/blob/b22c2adb617bf5df982ca2492624fdef780c4913/LICENSE) is MIT. |
| Model/data license | The README recommends [MostafaAhmed98/Conformer-CTC-Arabic-ASR](https://huggingface.co/MostafaAhmed98/Conformer-CTC-Arabic-ASR); its own model card labels the fine-tuned NeMo Conformer MIT and describes Common Voice training. The application also offers Groq-hosted Whisper, which is not the same model. Correspondence of the bundled local checkpoint to the recommended artifact and rights in the bundled text remain unverified. No checkpoint/audio was fetched for this comparison. |

## Tarteel

| Cell | Evidence and qualification |
|---|---|
| Integrates from | Its [developer FAQ](https://support.tarteel.ai/en/articles/12414464-do-you-have-an-api-i-can-use) says there is no public API for developers/external applications and directs developers to QUL resources. This comparison concerns the app's recitation recognizer, not separate resource services or a private partnership. |
| Platforms | The [desktop FAQ](https://support.tarteel.ai/en/articles/12414477-can-i-use-tarteel-on-my-computer) identifies the iOS/Android app paths and permits Apple Silicon Macs through the iOS app; it does not claim a dedicated desktop experience. |
| Code license | [Terms of Service](https://tarteel.ai/terms), specifically service-content ownership and the mobile-app license, reserve proprietary rights and prohibit deriving the app source. The live page was read from its server-rendered Next.js response because the web text extractor exposed only the title. No app code was downloaded. |
| Model/data license | The [model FAQ](https://support.tarteel.ai/en/articles/12414469-what-ml-model-algorithms-techniques-do-you-use) identifies a modified NVIDIA NeMo CitriNet lineage, but does not grant redistribution rights to recognition weights. [Quran resource FAQ](https://support.tarteel.ai/en/articles/12414474-where-can-i-find-the-quranic-resources-that-you-use) separately describes QUL's collected/released resources. A blanket proprietary or open license for all model/data cannot be established from these pages: the cell therefore says unverified. |

## Scope of this change

The comparison is in the README, not the v0.1.0/v0.1.1 release notes. No performance ranking, priority claim, or assertion that a competitor cannot add another integration path is made. The clean-model workflow has an independent promotion gate; its status does not silently change the table's licensing qualification.
