import AVFoundation
import Foundation
import QuranRecitationKit
import QuranRecitationAudio

func run() async throws -> Int32 {
    let args = Array(CommandLine.arguments.dropFirst())
    func value(_ name: String) -> String? {
        guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }
        return args[index + 1]
    }
    guard let surah = value("--surah").flatMap(Int.init), let path = value("--wav") else {
        print("Usage: recite-cli --surah N [--ayahs a-b] --wav FILE [--model DIRECTORY]")
        return args.contains("--help") ? 0 : 2
    }
    let quran = try QuranCatalog()
    guard let info = quran.surahs.first(where: { $0.number == surah }) else { throw CLIError.invalidArguments }
    let range: ClosedRange<Int>
    if let raw = value("--ayahs") {
        let components = raw.split(separator: "-").compactMap { Int($0) }
        guard components.count == 2, components[0] > 0, components[0] <= components[1], components[1] <= info.ayahCount else { throw CLIError.invalidArguments }
        range = components[0]...components[1]
    } else { range = 1...info.ayahCount }
    let pack: ModelPack
    if let directory = value("--model") { pack = try ModelPack(directory: URL(fileURLWithPath: directory)) }
    else { pack = try await ModelPack.download() }
    let recognizer = try await RecitationRecognizer(modelPack: pack)
    try await recognizer.setExpected(.ayahs(surah: surah, range: range))
    let events = Task {
        for await event in recognizer.events {
            switch event {
            case .state(let state): print("state \(state.rawValue)")
            case .rawTranscript(let text): print("transcript \(text.text)")
            case .wordProgress(let p): print("wordProgress \(p.surah):\(p.ayah) word=\(p.wordIndex) matched=\(p.matchedWordIndices.sorted()) confidence=\(String(format: "%.3f", p.confidence))")
            case .verseMatch(let m): print("verseMatch \(m.surah):\(m.ayah) confidence=\(String(format: "%.3f", m.confidence)) duration=\(String(format: "%.2f", m.durationSeconds))")
            case .needsRetry(let reason): print("needsRetry \(reason.rawValue)")
            }
            if case .state(.ended) = event { break }
        }
    }
    // AVAudioFile decodes 16-bit PCM and Float32 WAV to non-interleaved Float32.
    let file = try AVAudioFile(forReading: URL(fileURLWithPath: path), commonFormat: .pcmFormatFloat32, interleaved: false)
    let format = file.processingFormat
    guard format.channelCount > 0, format.sampleRate > 0 else { throw CLIError.invalidAudio }
    var resampler = AudioResampler(inputSampleRate: format.sampleRate)
    var pending: [Float] = []
    while file.framePosition < file.length {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192) else { throw CLIError.invalidAudio }
        try file.read(into: buffer)
        guard let channels = buffer.floatChannelData else { throw CLIError.invalidAudio }
        var mono = [Float](repeating: 0, count: Int(buffer.frameLength))
        for c in 0..<Int(format.channelCount) {
            for i in mono.indices { mono[i] += channels[c][i] / Float(format.channelCount) }
        }
        pending.append(contentsOf: resampler.process(mono))
        while pending.count >= 4800 {
            await recognizer.feed(Array(pending.prefix(4800))); pending.removeFirst(4800)
            // Yield to the bounded consumer without requiring wall-clock playback.
            await Task.yield()
        }
    }
    if !pending.isEmpty { await recognizer.feed(pending) }
    let summary = try await recognizer.stop()
    await events.value
    print("summary verses=\(summary.verses.count)/\(range.count) duration=\(String(format: "%.2f", summary.duration)) transcript=\(summary.transcript)")
    return Set(summary.verses.map(\.ayah)) == Set(range) ? 0 : 1
}
enum CLIError: Error { case invalidArguments, invalidAudio }
let exitCode: Int32
 do { exitCode = try await run() }
 catch { fputs("recite-cli: \(error.localizedDescription)\n", stderr); exitCode = 2 }
exit(exitCode)
