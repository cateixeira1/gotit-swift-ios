import SwiftUI
import UIKit
import PencilKit
import GotItDomain
import GotItPersistence
import GotItCanvas
import GotItCanvasUI
#if !targetEnvironment(macCatalyst)
import os
#endif

/// Measures, on the user's own device, what each keystroke, drawing and shape check costs, with
/// throw-away data in a temporary folder (the user's notes are not touched). The numbers are
/// what the stage-2 criteria ask for and could not be measured without a device.
@MainActor enum DevicePerformance {
    struct Line: Identifiable {
        let id = UUID()
        let title: String
        let value: String
    }

    static func run(progress: @escaping (String) -> Void) async -> [Line] {
        var lines: [Line] = [Line(title: "Aparelho", value: deviceDescription())]
        let startPeak = peakMemoryMB()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("gotit-medicao-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for pages in [1, 10, 30] {
                progress("Digitação numa história de \(pages) página(s)…")
                var (document, story) = try await longStory(pages: pages, paragraphs: true)
                let made = document.pages.count
                let end = try await typing(in: &document, story: story, atStart: false, keys: 25)
                let start = try await typing(in: &document, story: story, atStart: true, keys: 12)
                lines.append(Line(title: "Digitar no fim · \(made) página(s)", value: summary(end)))
                lines.append(Line(title: "Digitar no início · \(made) página(s)", value: summary(start)))
            }
            // Worst case: one paragraph 30 pages long, every line moves when a letter is added at its start.
            progress("Digitação num parágrafo único de 30 páginas…")
            var (single, singleStory) = try await longStory(pages: 30, paragraphs: false)
            let worst = try await typing(in: &single, story: singleStory, atStart: true, keys: 6)
            lines.append(Line(title: "Digitar no início de um parágrafo único · \(single.pages.count) páginas", value: summary(worst)))
            progress("Gravação de cada tecla…")
            lines += try await saving(in: folder)
            progress("Desenho…")
            lines += drawing()
            progress("Formas…")
            lines.append(Line(title: "Reconhecer uma forma (por traço)", value: summary(shapes())))
        } catch {
            lines.append(Line(title: "Medição interrompida", value: String(describing: error)))
        }
        lines.append(Line(title: "Memória", value: memoryDescription(startPeak: startPeak)))
        lines.append(Line(title: "Referência", value: "Um quadro de tela dura 16,7 ms a 60 Hz e 8,3 ms a 120 Hz."))
        return lines
    }

    static func report(_ lines: [Line]) -> String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return (["Got It! \(version) (\(build)) — medição de desempenho"] + lines.map { "\($0.title): \($0.value)" }).joined(separator: "\n")
    }

    // MARK: Workloads

    /// A story long enough to fill about `pages` A4 pages at 18 pt, already paginated.
    private static func longStory(pages: Int, paragraphs: Bool) async throws -> (CanvasDocument, UUID) {
        var document = CanvasDocument(title: "Medição", defaultStyle: .init(fontSize: 18))
        var block = CanvasBlock(layout: .init(mode: .absolute, frame: .init(x: 24, y: 24, width: document.canvas.size.width - 48, height: 44)),
                                content: .text(.init("")))
        block.textFlowID = block.id
        document.blocks = [block]
        let sentence = "Esta é uma frase de teste, com acentuação, números como 1234 e pontuação; ela se repete até encher as páginas. "
        // About 22 sentences per page; with paragraphs, a new one every 5 sentences.
        let body = (0..<(pages * 22)).map { index in sentence + (paragraphs && index % 5 == 4 ? "\n" : "") }.joined()
        block.content = .text(RichText(body))
        let result = try TextPagination.reflow(block, in: document, selection: NSRange(location: 0, length: 0))
        document = try CommandEngine.applying(result.commands, to: document)
        await Task.yield()
        return (document, block.id)
    }

    /// Time to lay out the story again after one key, which the editor does on every keystroke.
    private static func typing(in document: inout CanvasDocument, story: UUID, atStart: Bool, keys: Int) async throws -> [Double] {
        var times: [Double] = []
        for _ in 0..<keys {
            let fragments = document.textFlowFragments(story: story)
            guard var target = atStart ? fragments.first : fragments.last, case .text(let rich) = target.content else { break }
            let text = atStart ? "a" + rich.plainText : rich.plainText + "a"
            target.content = .text(RichText(text))
            let caret = atStart ? 1 : (text as NSString).length
            let began = ContinuousClock.now
            let result = try TextPagination.reflow(target, in: document, selection: NSRange(location: caret, length: 0))
            document = try CommandEngine.applying(result.commands, to: document)
            times.append(milliseconds(ContinuousClock.now - began))
            await Task.yield()
        }
        return times
    }

    /// One keystroke on a 30-page note: the recovery journal, then the SQLite commit with history.
    private static func saving(in folder: URL) async throws -> [Line] {
        var (document, story) = try await longStory(pages: 30, paragraphs: true)
        let store = try SQLiteStore(url: folder.appendingPathComponent("medicao.sqlite"))
        var revision = try await store.create(document).revision
        let journal = try PendingEditJournal(url: folder.appendingPathComponent("medicao.jsonl"))
        var commits: [Double] = [], appends: [Double] = []
        for _ in 0..<20 {
            guard var last = document.textFlowFragments(story: story).last, case .text(let rich) = last.content else { break }
            let text = rich.plainText + "a"
            last.content = .text(RichText(text))
            let commands = try TextPagination.reflow(last, in: document, selection: NSRange(location: (text as NSString).length, length: 0)).commands
            let edit = PendingEdit(documentID: document.id, expectedRevision: revision, commands: commands)
            var began = ContinuousClock.now
            try journal.append(edit)
            appends.append(milliseconds(ContinuousClock.now - began))
            began = ContinuousClock.now
            let saved = try await store.execute(commands, documentID: document.id, expectedRevision: revision, operationID: edit.id)
            commits.append(milliseconds(ContinuousClock.now - began))
            try journal.remove(edit.id)
            document = saved; revision = saved.revision
        }
        try await store.close()
        return [Line(title: "Fila de recuperação (por tecla)", value: summary(appends)),
                Line(title: "Gravar no banco com histórico (por tecla, 30 páginas)", value: summary(commits))]
    }

    /// The page's drawing is saved whole after each stroke; this is that cost as drawings grow.
    private static func drawing() -> [Line] {
        var lines: [Line] = []
        for count in [100, 500, 1500] {
            var strokes: [PKStroke] = []
            for index in 0..<count {
                let x = Double(index % 30) * 18, y = Double(index / 30) * 16
                let points = (0..<40).map { step in
                    PKStrokePoint(location: CGPoint(x: x + Double(step) * 0.4, y: y + sin(Double(step) / 4) * 5), timeOffset: Double(step) / 120,
                                  size: CGSize(width: 3, height: 3), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
                }
                strokes.append(PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: points, creationDate: Date())))
            }
            let drawing = PKDrawing(strokes: strokes)
            var encode: [Double] = [], decode: [Double] = []
            var bytes = 0
            for _ in 0..<5 {
                var began = ContinuousClock.now
                let data = drawing.dataRepresentation()
                encode.append(milliseconds(ContinuousClock.now - began)); bytes = data.count
                began = ContinuousClock.now
                _ = try? PKDrawing(data: data)
                decode.append(milliseconds(ContinuousClock.now - began))
            }
            lines.append(Line(title: "Salvar desenho com \(count) traços (\(bytes / 1024) KB)", value: "gravar \(summary(encode)) · abrir \(summary(decode))"))
        }
        return lines
    }

    private static func shapes() -> [Double] {
        var times: [Double] = []
        for index in 0..<60 {
            let wobble = Double(index % 7)
            let circle = (0...80).map { i -> CanvasPoint in
                let t = 2 * Double.pi * Double(i) / 80
                return .init(x: 200 + (90 + wobble) * cos(t), y: 200 + 70 * sin(t))
            }
            let box = [CanvasPoint(x: 0, y: 0), .init(x: 220, y: wobble), .init(x: 216, y: 140), .init(x: wobble, y: 136), .init(x: 1, y: 2)]
                .flatMap { corner in (0..<12).map { CanvasPoint(x: corner.x + Double($0), y: corner.y + Double($0) * 0.2) } }
            for stroke in [circle, box] {
                let began = ContinuousClock.now
                _ = ShapeRecognizer.recognize([stroke], intent: .automatic)
                times.append(milliseconds(ContinuousClock.now - began))
            }
        }
        return times
    }

    // MARK: Reporting

    private static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }
    private static func format(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(value < 10 ? 1 : 0)).locale(Locale(identifier: "pt_BR")))
    }
    /// Median, 95th percentile and maximum, in milliseconds.
    static func summary(_ samples: [Double]) -> String {
        guard !samples.isEmpty else { return "sem amostras" }
        let sorted = samples.sorted()
        func percentile(_ p: Double) -> Double { sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded()))] }
        return "mediana \(format(percentile(0.5))) ms · p95 \(format(percentile(0.95))) ms · máx \(format(sorted.last!)) ms"
    }

    private static func deviceDescription() -> String {
        var system = utsname()
        uname(&system)
        let machine = withUnsafeBytes(of: &system.machine) { raw in String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self) }
        return "\(machine), \(UIDevice.current.systemName) \(UIDevice.current.systemVersion)"
    }
    /// Highest resident memory of the app so far (getrusage), in MB.
    private static func peakMemoryMB() -> Double {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return -1 }
        return Double(usage.ru_maxrss) / 1_048_576
    }
    private static func memoryDescription(startPeak: Double) -> String {
        var text = "pico do app \(format(peakMemoryMB())) MB (antes da medição \(format(startPeak)) MB)"
        #if !targetEnvironment(macCatalyst)
        text += " · ainda disponível ao app \(format(Double(os_proc_available_memory()) / 1_048_576)) MB"
        #endif
        return text
    }
}

struct DiagnosticsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var lines: [DevicePerformance.Line] = []
    @State private var status = ""
    @State private var running = false
    @State private var copied = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Mede neste aparelho o tempo de cada tecla em textos longos, de gravar cada edição, de salvar desenhos e de reconhecer formas, além da memória usada. Usa dados de teste temporários: suas notas não são alteradas. Leva alguns segundos.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if running {
                    Section { HStack(spacing: 12) { ProgressView(); Text(status).font(.callout) } }
                }
                if !lines.isEmpty {
                    Section("Resultados") {
                        ForEach(lines) { line in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(line.title).font(.subheadline.weight(.semibold))
                                Text(line.value).font(.callout.monospacedDigit()).textSelection(.enabled)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Desempenho")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Fechar") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    if lines.isEmpty {
                        Button("Medir") { measure() }.disabled(running).accessibilityIdentifier("runDiagnostics")
                    } else {
                        Button(copied ? "Copiado" : "Copiar resultados") {
                            UIPasteboard.general.string = DevicePerformance.report(lines); copied = true
                        }
                    }
                }
            }
        }
    }

    private func measure() {
        running = true
        Task {
            let result = await DevicePerformance.run { status = $0 }
            lines = result; running = false
        }
    }
}

/// The user's strokes of one note, as JSON, to tune shape recognition on real handwriting.
struct InkSampleFile: Codable {
    struct Stroke: Codable {
        /// "tinta" (left as ink), a shape kind ("rectangle", "triangle"…) it became, or "conector".
        var kind: String
        var page: Int
        /// [x, y, seconds since the stroke started]; shapes keep no times (0).
        var points: [[Double]]
    }
    var app: String
    var device: String
    var exportedAt: Date
    var strokes: [Stroke]
}

struct ShareFile: Identifiable {
    let id = UUID()
    let url: URL
}

struct ActivitySheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
