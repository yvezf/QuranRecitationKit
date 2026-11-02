using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using Microsoft.Win32.SafeHandles;
namespace QuranRecitationKit
{
    public sealed class RecitationTarget
    {
        internal object Wire { get; }
        private RecitationTarget(object value) { Wire = value; }
        public static RecitationTarget Surah(int number) => new RecitationTarget(new { surah = number });
        public static RecitationTarget Ayahs(int surah, int from, int to) => new RecitationTarget(new { surah, from, to });
        /// <summary>Zero-based, half-open word offsets.</summary>
        public static RecitationTarget Words(int surah, int ayah, int from, int to) => new RecitationTarget(new { surah, ayah, from, to });
    }
    public sealed class RecitationConfiguration
    {
        [JsonPropertyName("live_tracking")] public bool LiveTracking { get; set; } = true;
        [JsonPropertyName("maximum_window_seconds")] public double MaximumWindowSeconds { get; set; } = 12;
        [JsonPropertyName("backtrack_words")] public int BacktrackWords { get; set; } = 3;
        [JsonPropertyName("lookahead_words")] public int LookaheadWords { get; set; } = 32;
        [JsonPropertyName("policy")] public string Policy { get; set; } = "balanced";
    }
    /// <summary>Calls are serialized. Inference runs on the calling thread; use a worker in GUI hosts.</summary>
    public sealed class RecitationRecognizer : IDisposable
    {
        private readonly NativeHandle handle;
        private readonly object gate = new object();
        private bool dispatching;
        /// <summary>Borrowed native data is copied before dispatch. JsonElement remains usable after the callback.</summary>
        public event Action<JsonElement>? Event;
        public RecitationRecognizer(string modelDirectory, RecitationConfiguration? configuration = null)
        {
            Native.Check(Native.qrk_recognizer_new(modelDirectory, IntPtr.Zero, JsonSerializer.Serialize(configuration ?? new RecitationConfiguration()), out var pointer));
            handle = new NativeHandle(pointer);
        }
        public static string Version => Native.Read(Native.qrk_version());
        private void Guard()
        {
            if (handle.IsClosed) throw new ObjectDisposedException(nameof(RecitationRecognizer));
            if (dispatching) throw new InvalidOperationException("Do not mutate or dispose this recognizer inside an event callback.");
        }
        public void SetExpected(RecitationTarget target)
        {
            if (target == null) throw new ArgumentNullException(nameof(target));
            lock (gate) { Guard(); Native.Check(Native.qrk_set_expected(handle, JsonSerializer.Serialize(target.Wire))); }
        }
        public IReadOnlyList<JsonElement> Feed(float[] pcm16k)
        {
            if (pcm16k == null) throw new ArgumentNullException(nameof(pcm16k));
            if (pcm16k.Length > 960000) throw new ArgumentException("At most 60 seconds per feed.", nameof(pcm16k));
            lock (gate)
            {
                Guard(); var events = new List<JsonElement>(); Exception? failure = null;
                Native.EventCallback callback = (pointer, context) => { try { events.Add(Parse(Native.Read(pointer))); } catch (Exception e) { failure = e; } };
                Native.Check(Native.qrk_feed(handle, pcm16k, (UIntPtr)pcm16k.Length, callback, IntPtr.Zero));
                GC.KeepAlive(callback); if (failure != null) throw failure;
                Dispatch(events); return events;
            }
        }
        public JsonElement Stop()
        {
            lock (gate)
            {
                Guard(); Native.Check(Native.qrk_stop(handle, out var pointer));
                JsonElement summary; try { summary = Parse(Native.Read(pointer)); } finally { Native.qrk_string_free(pointer); }
                var events = new List<JsonElement>(); foreach (var e in summary.GetProperty("events").EnumerateArray()) events.Add(e.Clone());
                Dispatch(events); return summary;
            }
        }
        public void Reset() { lock (gate) { Guard(); Native.Check(Native.qrk_reset(handle)); } }
        public void Dispose() { lock (gate) { if (handle.IsClosed) return; Guard(); handle.Dispose(); } }
        private void Dispatch(IEnumerable<JsonElement> events) { dispatching = true; try { foreach (var e in events) Event?.Invoke(e); } finally { dispatching = false; } }
        private static JsonElement Parse(string text) { using (var doc = JsonDocument.Parse(text)) return doc.RootElement.Clone(); }
    }
    public sealed class RecitationSpotter : IDisposable
    {
        private readonly NativeHandle handle;
        private readonly object gate = new object();
        private bool dispatching;
        /// <summary>Borrowed native data is copied before dispatch. JsonElement remains usable after the callback.</summary>
        public event Action<JsonElement>? Event;
        public RecitationSpotter(string modelDirectory, SpotConfiguration? configuration = null)
        {
            Native.Check(Native.qrk_spotter_new(modelDirectory, IntPtr.Zero, JsonSerializer.Serialize(configuration ?? new SpotConfiguration()), out var pointer));
            handle = new NativeHandle(pointer,true);
        }
        public static string Version => Native.Read(Native.qrk_version());
        private void Guard()
        {
            if (handle.IsClosed) throw new ObjectDisposedException(nameof(RecitationSpotter));
            if (dispatching) throw new InvalidOperationException("Do not mutate or dispose this recognizer inside an event callback.");
        }
        public static JsonElement MatchText(string text) => QuotationMatcher.MatchText(text);
        public IReadOnlyList<JsonElement> Feed(float[] pcm16k)
        {
            if (pcm16k == null) throw new ArgumentNullException(nameof(pcm16k));
            if (pcm16k.Length > 960000) throw new ArgumentException("At most 60 seconds per feed.", nameof(pcm16k));
            lock (gate)
            {
                Guard(); var events = new List<JsonElement>(); Exception? failure = null;
                Native.EventCallback callback = (pointer, context) => { try { events.Add(Parse(Native.Read(pointer))); } catch (Exception e) { failure = e; } };
                Native.Check(Native.qrk_spotter_feed(handle, pcm16k, (UIntPtr)pcm16k.Length, callback, IntPtr.Zero));
                GC.KeepAlive(callback); if (failure != null) throw failure;
                Dispatch(events); return events;
            }
        }
        public JsonElement Stop()
        {
            lock (gate)
            {
                Guard(); Native.Check(Native.qrk_spotter_stop(handle, out var pointer));
                JsonElement summary; try { summary = Parse(Native.Read(pointer)); } finally { Native.qrk_string_free(pointer); }
                var events = new List<JsonElement>(); foreach (var e in summary.GetProperty("events").EnumerateArray()) events.Add(e.Clone());
                Dispatch(events); return summary;
            }
        }
        public void Reset() { lock (gate) { Guard(); Native.Check(Native.qrk_spotter_reset(handle)); } }
        public void Dispose() { lock (gate) { if (handle.IsClosed) return; Guard(); handle.Dispose(); } }
        private void Dispatch(IEnumerable<JsonElement> events) { dispatching = true; try { foreach (var e in events) Event?.Invoke(e); } finally { dispatching = false; } }
        private static JsonElement Parse(string text) { using (var doc = JsonDocument.Parse(text)) return doc.RootElement.Clone(); }
    }
    public static class ModelPack
    {
        /// <summary>Blocking, verified download. The release owner must be configured by the publisher.</summary>
        public static string Fetch(string? cacheDirectory = null, Action<double>? progress = null)
        {
            Exception? failure = null;
            Native.ProgressCallback callback = (value, user) => { try { progress?.Invoke(value); } catch (Exception e) { failure = e; } };
            Native.Check(Native.qrk_model_fetch(cacheDirectory, callback, IntPtr.Zero)); GC.KeepAlive(callback);
            if (failure != null) throw failure;
            if (cacheDirectory != null) return cacheDirectory;
            var sourcePointer = Native.qrk_model_source_json();
            try
            {
                using (var source = JsonDocument.Parse(Native.Read(sourcePointer)))
                {
                    if (source.RootElement.TryGetProperty("cache_directory", out var cache))
                        return cache.GetString() ?? throw new InvalidOperationException("Native cache path is missing.");
                    // Compatibility with older native archives: use the tag in their URL.
                    var url = new Uri(source.RootElement.GetProperty("url").GetString()!);
                    var segments = url.Segments;
                    var release = segments[segments.Length - 2].Trim('/');
                    var p = Native.qrk_cache_directory();
                    try { return System.IO.Path.Combine(Native.Read(p), release); }
                    finally { Native.qrk_string_free(p); }
                }
            }
            finally { Native.qrk_string_free(sourcePointer); }
        }
    }
    public sealed class SpotConfiguration {
        [JsonPropertyName("window_seconds")] public double WindowSeconds {get;set;}=8;
        [JsonPropertyName("min_words")] public int MinimumWords {get;set;}=3;
        [JsonPropertyName("min_seconds")] public double MinimumSeconds {get;set;}=1.5;
        [JsonPropertyName("min_margin")] public double MinimumMargin {get;set;}=0.035;
        [JsonPropertyName("high_margin")] public double HighMargin {get;set;}=0.20;
        [JsonPropertyName("ambiguity_margin")] public double AmbiguityMargin {get;set;}=0.05;
        [JsonPropertyName("max_candidates")] public int MaximumCandidates {get;set;}=8;
    }
    public static class QuotationMatcher {
        /// <summary>Model-free, always unverified; results are candidates, never automatic replacements.</summary>
        public static JsonElement MatchText(string text) {
            if(text==null)throw new ArgumentNullException(nameof(text));
            Native.Check(Native.qrk_match_text(text,out var pointer));
            try {using(var doc=JsonDocument.Parse(Native.Read(pointer)))return doc.RootElement.Clone();}
            finally {Native.qrk_string_free(pointer);}
        }
    }
    internal sealed class NativeHandle : SafeHandleZeroOrMinusOneIsInvalid
    {
        private readonly bool spotting;
        internal NativeHandle(IntPtr pointer,bool spotting=false) : base(true) {this.spotting=spotting; SetHandle(pointer); }
        protected override bool ReleaseHandle() { if(spotting)Native.qrk_spotter_free(handle);else Native.qrk_free(handle); return true; }
    }
    internal sealed class Utf8Marshaller : ICustomMarshaler
    {
        private static readonly Utf8Marshaller Instance = new Utf8Marshaller();
        public static ICustomMarshaler GetInstance(string cookie) => Instance;
        public IntPtr MarshalManagedToNative(object value)
        {
            if (value == null) return IntPtr.Zero;
            var bytes = Encoding.UTF8.GetBytes((string)value + "\0"); var p = Marshal.AllocHGlobal(bytes.Length); Marshal.Copy(bytes, 0, p, bytes.Length); return p;
        }
        public object MarshalNativeToManaged(IntPtr p) => Native.Read(p);
        public void CleanUpNativeData(IntPtr p) { if (p != IntPtr.Zero) Marshal.FreeHGlobal(p); }
        public void CleanUpManagedData(object value) { }
        public int GetNativeDataSize() => -1;
    }
    internal static class Native
    {
        private const string Library = "qrk";
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] internal delegate void EventCallback(IntPtr json, IntPtr user);
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] internal delegate void ProgressCallback(double value, IntPtr user);
        [DllImport(Library, CallingConvention = CallingConvention.Cdecl)] internal static extern int qrk_spotter_new([MarshalAs(UnmanagedType.CustomMarshaler, MarshalTypeRef = typeof(Utf8Marshaller))] string model, IntPtr corpus, [MarshalAs(UnmanagedType.CustomMarshaler, MarshalTypeRef = typeof(Utf8Marshaller))] string config, out IntPtr handle);
        [DllImport(Library, CallingConvention = CallingConvention.Cdecl)] internal static extern int qrk_spotter_feed(NativeHandle h, [In] float[] samples, UIntPtr count, EventCallback callback, IntPtr user);
        [DllImport(Library, CallingConvention = CallingConvention.Cdecl)] internal static extern int qrk_spotter_stop(NativeHandle h,out IntPtr result);
        [DllImport(Library, CallingConvention = CallingConvention.Cdecl)] internal static extern int qrk_spotter_reset(NativeHandle h);
        [DllImport(Library, CallingConvention = CallingConvention.Cdecl)] internal static extern void qrk_spotter_free(IntPtr h);
        [DllImport(Library, CallingConvention = CallingConvention.Cdecl)] internal static extern int qrk_match_text([MarshalAs(UnmanagedType.CustomMarshaler, MarshalTypeRef = typeof(Utf8Marshaller))] string text,out IntPtr result);
        [DllImport(Library, CallingConvention = CallingConvention.Cdecl)] internal static extern IntPtr qrk_version();
        [DllImport(Library, CallingConvention = CallingConvention.Cdecl)] internal static extern IntPtr qrk_last_error();
        [DllImport(Library, CallingConvention = CallingConvention.Cdecl)] internal static extern int qrk_recognizer_new([MarshalAs(UnmanagedType.CustomMarshaler, MarshalTypeRef = typeof(Utf8Marshaller))] string model, IntPtr corpus, [MarshalAs(UnmanagedType.CustomMarshaler, MarshalTypeRef = typeof(Utf8Marshaller))] string config, out IntPtr handle);
        [DllImport(Library, CallingConvention = CallingConvention.Cdecl)] internal static extern int qrk_set_expected(NativeHandle h, [MarshalAs(UnmanagedType.CustomMarshaler, MarshalTypeRef = typeof(Utf8Marshaller))] string json);
        [DllImport(Library, CallingConvention = CallingConvention.Cdecl)] internal static extern int qrk_feed(NativeHandle h, [In] float[] samples, UIntPtr count, EventCallback callback, IntPtr user);
        [DllImport(Library, CallingConvention = CallingConvention.Cdecl)] internal static extern int qrk_stop(NativeHandle h, out IntPtr summary);
        [DllImport(Library, CallingConvention = CallingConvention.Cdecl)] internal static extern int qrk_reset(NativeHandle h);
        [DllImport(Library, CallingConvention = CallingConvention.Cdecl)] internal static extern void qrk_free(IntPtr h);
        [DllImport(Library, CallingConvention = CallingConvention.Cdecl)] internal static extern void qrk_string_free(IntPtr s);
        [DllImport(Library, CallingConvention = CallingConvention.Cdecl)] internal static extern IntPtr qrk_cache_directory();
        [DllImport(Library, CallingConvention = CallingConvention.Cdecl)] internal static extern IntPtr qrk_model_source_json();
        [DllImport(Library, CallingConvention = CallingConvention.Cdecl)] internal static extern int qrk_model_fetch([MarshalAs(UnmanagedType.CustomMarshaler, MarshalTypeRef = typeof(Utf8Marshaller))] string? cache, ProgressCallback callback, IntPtr user);
        internal static void Check(int status) { if (status != 0) throw new InvalidOperationException(Read(qrk_last_error())); }
        internal static string Read(IntPtr p)
        {
            if (p == IntPtr.Zero) throw new InvalidOperationException("Native engine returned no string.");
            int n = 0; while (n < 16777216 && Marshal.ReadByte(p, n) != 0) n++;
            if (n == 16777216) throw new InvalidOperationException("Native string exceeds limit.");
            var bytes = new byte[n]; Marshal.Copy(p, bytes, 0, n); return Encoding.UTF8.GetString(bytes);
        }
    }
}
