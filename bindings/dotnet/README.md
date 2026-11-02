# .NET binding

The four-platform package is available at https://github.com/yvezf/QuranRecitationKit/releases/download/v0.2.1/QuranRecitationKit.0.2.1.nupkg. It has not been published to the NuGet registry. Use it as a local package feed, with NuGet.org retained for Microsoft dependencies; see the root README.

`netstandard2.0` P/Invoke facade, compatible with modern .NET, WPF, WinForms, Unity hosts that support the native ABI, and other .NET applications. One recognizer is serialized; run Feed on a worker for GUI applications. Event handlers run synchronously on that worker and receive owned JSON values matching the shared schema. Do not re-enter session methods inside a handler.

```csharp
using QuranRecitationKit;
using var r = new RecitationRecognizer("/path/to/model");
r.Event += e => Console.WriteLine(e.GetRawText());
r.SetExpected(RecitationTarget.Surah(112));
r.Feed(new float[16000]); // replace silence with your own 16 kHz mono PCM
var summary = r.Stop();
```

Native assets belong under `runtimes/osx-arm64/native/libqrk.dylib`, `osx-x64`, `win-x64/native/qrk.dll`, and `linux-x64/native/libqrk.so`. The release workflow stages these before packing the NuGet. A source-only pack without those assets is incomplete; the packaging script refuses it. Source build: build `core/qrk-ffi`, then stage with `tools/package_dotnet.py --rid osx-arm64`; build or pack the csproj. For local project-reference testing, set the platform native search path to the compiled library directory. The NuGet loader selects runtime assets for normal package consumers. Do not rename the library.

Model downloads are explicit and SHA pinned. `ModelPack.Fetch()` uses the configured public model-v2 release; a local model directory works immediately. No automatic microphone capture: feed PCM from your host or use the universal `qrk mic` helper. Windows may require Microsoft's current VC++ Redistributable for the chosen ONNX Runtime build.
