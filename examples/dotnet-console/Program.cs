using System;
using System.IO;
using System.Text;
using QuranRecitationKit;
Console.WriteLine("QuranRecitationKit " + RecitationRecognizer.Version);
if (args.Length == 0) { Console.WriteLine("Pass a model directory to run a silence smoke test."); return; }
using var recognizer = new RecitationRecognizer(args[0]);
recognizer.Event += e => Console.WriteLine(e.GetRawText());
if (args.Length > 1)
{
    int surah = args.Length > 2 ? int.Parse(args[2]) : 112;
    int from = args.Length > 3 ? int.Parse(args[3]) : 1;
    int to = args.Length > 4 ? int.Parse(args[4]) : from;
    recognizer.SetExpected(RecitationTarget.Ayahs(surah, from, to));
    using var reader = new BinaryReader(File.OpenRead(args[1]));
    string Tag() => Encoding.ASCII.GetString(reader.ReadBytes(4));
    if (Tag() != "RIFF") throw new Exception("Expected RIFF WAV"); reader.ReadUInt32(); if (Tag() != "WAVE") throw new Exception("Expected WAVE");
    bool formatOk = false;
    while (reader.BaseStream.Position + 8 <= reader.BaseStream.Length)
    {
        var tag = Tag(); var size = reader.ReadUInt32(); long end = reader.BaseStream.Position + size;
        if (end > reader.BaseStream.Length) throw new Exception("Truncated WAV");
        if (tag == "fmt ") { var code = reader.ReadUInt16(); var channels = reader.ReadUInt16(); var rate = reader.ReadUInt32(); reader.ReadUInt32(); reader.ReadUInt16(); var bits = reader.ReadUInt16(); formatOk = code == 1 && channels == 1 && rate == 16000 && bits == 16; }
        else if (tag == "data")
        {
            if (!formatOk || size % 2 != 0) throw new Exception("Use mono PCM16 16 kHz WAV");
            while (reader.BaseStream.Position < end) { int n = (int)Math.Min(4800, (end - reader.BaseStream.Position) / 2); var pcm = new float[n]; for (int i = 0; i < n; i++) pcm[i] = reader.ReadInt16() / 32768f; recognizer.Feed(pcm); }
            break;
        }
        reader.BaseStream.Position = end + (size % 2);
    }
}
else { recognizer.SetExpected(RecitationTarget.Surah(112)); recognizer.Feed(new float[16000]); }
var summary = recognizer.Stop();
int expected = args.Length > 1 ? (args.Length > 4 ? int.Parse(args[4]) - int.Parse(args[3]) + 1 : 1) : 0;
if (summary.GetProperty("verses").GetArrayLength() != expected) throw new Exception("Unexpected verse count");
Console.WriteLine(summary.GetRawText());
recognizer.Reset();
Console.WriteLine("DOTNET PASS");
