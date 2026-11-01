import AVFoundation
import SwiftUI
import QuranRecitationKit
import QuranRecitationAudio

@main
struct RecitationDemoApp: App {
    var body: some Scene { WindowGroup { RecitationView() } }
}
@MainActor
final class DemoModel: ObservableObject {
    @Published var catalog: QuranCatalog?
    @Published var selected = 112
    @Published var downloading = false
    @Published var progress = 0.0
    @Published var ready = false
    @Published var recording = false
    @Published var level: Float = 0
    @Published var message = "Download the model once. Recite offline afterwards."
    @Published var matched: [Int: Set<Int>] = [:]
    @Published var completed: Set<Int> = []
    @Published var activeAyah = 1
    private var recognizer: RecitationRecognizer?
    private var microphone: RecitationMicrophone?
    private var events: Task<Void,Never>?
    private var meter: Task<Void,Never>?
    init() { do { catalog = try QuranCatalog() } catch { message = error.localizedDescription } }
    deinit { events?.cancel(); meter?.cancel(); microphone?.stop() }
    func download() async {
        guard !downloading else { return }
        downloading = true
        defer { downloading = false }
        do {
            let pack = try await ModelPack.download { [weak self] value in Task { @MainActor in self?.progress = value } }
            let r = try await RecitationRecognizer(modelPack: pack)
            recognizer = r
            events = Task { [weak self] in
                for await event in r.events {
                    guard !Task.isCancelled else { break }
                    switch event {
                    case .wordProgress(let p): self?.matched[p.ayah] = p.matchedWordIndices; self?.activeAyah = p.ayah
                    case .verseMatch(let v): self?.completed.insert(v.ayah); self?.message = "Verse \(v.ayah) complete"
                    case .needsRetry: self?.message = "Couldn't tell that time. Take your time and try again."
                    case .state(.ended): self?.recording = false
                    default: break
                    }
                }
            }
            microphone = try RecitationMicrophone()
            if let microphone {
                meter = Task { [weak self] in for await value in microphone.inputLevel { self?.level = value } }
            }
            ready = true; message = "Ready. Choose a surah, then tap Record."
        } catch { message = error.localizedDescription }
    }
    func toggle() async {
        guard let recognizer, let microphone else { return }
        do {
            if recording {
                await microphone.stopAndDrain()
                let summary = try await recognizer.stop()
                recording = false; message = "\(summary.verses.count) verses completed."
            } else {
                matched = [:]; completed = []; activeAyah = 1
                try await recognizer.setExpected(.surah(selected))
                try await microphone.start { chunk in await recognizer.feed(chunk) }
                recording = true; message = "Listening. Recite at a comfortable pace."
            }
        } catch { microphone.stop(); recording = false; message = error.localizedDescription }
    }
    func stopForBackground() { microphone?.stop(); if recording { Task { await toggleAfterStop() } } }
    private func toggleAfterStop() async { await microphone?.stopAndDrain(); _ = try? await recognizer?.stop(); recording = false }
}
struct RecitationView: View {
    @StateObject private var model = DemoModel()
    @Environment(\.scenePhase) private var phase
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if !model.ready {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Offline recitation model").font(.headline)
                            Text("88 MB · Wi-Fi recommended · Audio stays on your device.")
                            if model.downloading { ProgressView(value: model.progress) }
                            Button(model.downloading ? "Downloading…" : "Download model") { Task { await model.download() } }
                                .buttonStyle(.borderedProminent).disabled(model.downloading)
                        }.padding().background(.quaternary, in: RoundedRectangle(cornerRadius: 16))
                    }
                    Picker("Surah", selection: $model.selected) {
                        ForEach(model.catalog?.surahs ?? []) { surah in Text("\(surah.number). \(surah.name)").tag(surah.number) }
                    }.disabled(model.recording)
                    Text(model.message).font(.callout).accessibilityLabel(model.message)
                    ProgressView(value: Double(model.level)).tint(.green).accessibilityLabel("Microphone input level")
                    Button { Task { await model.toggle() } } label: {
                        Label(model.recording ? "Stop" : "Record", systemImage: model.recording ? "stop.fill" : "mic.fill")
                            .font(.title2.bold()).frame(maxWidth: .infinity).padding()
                    }.buttonStyle(.borderedProminent).disabled(!model.ready)
                    if model.selected != 1, model.selected != 9,
                       let header = model.catalog?.surahs.first(where: { $0.number == model.selected })?.bismillah, !header.isEmpty {
                        Text(header).font(.system(size: 25)).frame(maxWidth: .infinity)
                    }
                    ForEach(model.catalog?.ayahs(in: model.selected) ?? []) { ayah in
                        VStack(alignment: .trailing, spacing: 12) {
                            HStack { Text("Ayah \(ayah.number)").font(.caption); Spacer(); if model.completed.contains(ayah.number) { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) } }
                            WordFlow(spacing: 10) {
                                ForEach(Array(ayah.words.enumerated()), id: \.offset) { index, word in
                                    Text(word).font(.system(size: 28)).foregroundStyle(model.matched[ayah.number]?.contains(index) == true ? .green : .primary)
                                }
                            }.environment(\.layoutDirection, .rightToLeft)
                        }.padding().background(.quaternary, in: RoundedRectangle(cornerRadius: 16))
                    }
                    Link("Arabic text: Tanzil Project · CC BY 3.0", destination: URL(string: "https://tanzil.net")!).font(.caption)
                    DisclosureGroup("Quran text licence") { Text(model.catalog?.attributionNotice ?? "").font(.caption) }
                }.padding()
            }.navigationTitle("Recitation Demo")
        }.onChange(of: phase) { next in if next != .active { model.stopForBackground() } }
    }
}
struct WordFlow: Layout {
    let spacing: CGFloat
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        layout(width: proposal.width ?? 300, subviews: subviews).0
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let positions = layout(width: bounds.width, subviews: subviews).1
        for (i,view) in subviews.enumerated() { view.place(at: CGPoint(x: bounds.minX + positions[i].x, y: bounds.minY + positions[i].y), proposal: .unspecified) }
    }
    private func layout(width: CGFloat, subviews: Subviews) -> (CGSize,[CGPoint]) {
        var x: CGFloat = 0; var y: CGFloat = 0; var height: CGFloat = 0; var points: [CGPoint] = []
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width { x = 0; y += height + spacing; height = 0 }
            points.append(CGPoint(x: x, y: y)); x += size.width + spacing; height = max(height,size.height)
        }
        return (CGSize(width: width, height: y + height),points)
    }
}
