import SwiftUI
import PhotosUI
import CryptoKit
import ImageIO
import GotItDomain
import GotItPersistence
import GotItCanvas
import GotItCanvasUI

@main
struct GotItDemoApp: App {
    @State private var model = DemoModel()
    var body: some Scene { WindowGroup { DemoScreen(model: model).task { await model.start() } } }
}

@Observable @MainActor
final class DemoModel {
    var document: CanvasDocument?
    var summaries: [DocumentSummary] = []
    var noteMetadata: [UUID: NoteCardPresentation] = [:]
    var error: String?
    var isSaving = false
    var writeFailed = false
    private var store: SQLiteStore?
    private var directory: URL?
    private var pending: [(UUID, Int64, [DocumentCommand])] = []
    private var images: [String: UIImage] = [:]

    func start() async {
        guard store == nil else { return }
        do {
            let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("GotItDemo")
            try FileManager.default.createDirectory(at: root.appendingPathComponent("assets"), withIntermediateDirectories: true)
            directory = root
            store = try SQLiteStore(url: root.appendingPathComponent("notes.sqlite"))
            try await refresh()
            if summaries.isEmpty { await createNote() }
            else if let first = summaries.first { await open(first.id) }
        } catch { self.error = String(describing: error) }
    }

    func refresh() async throws {
        guard let store else { return }
        summaries = try await store.listDocuments()
        for summary in summaries where summary.kind == .note {
            let note = try await store.load(summary.id)
            noteMetadata[summary.id] = .init(title: summary.title, createdAt: summary.createdAt, preview: preview(note))
        }
    }

    func open(_ id: UUID) async {
        guard !isSaving, let store else { return }
        do { document = try await store.load(id) }
        catch { self.error = String(describing: error) }
    }

    func createNote() async {
        guard !isSaving, let store else { return }
        do {
            document = try await store.create(.init(title: "Nota \(summaries.filter { $0.kind == .note }.count + 1)", defaultStyle: .init(fontSize: 18)))
            try await refresh()
        } catch { self.error = String(describing: error) }
    }

    func createWeb(including id: UUID? = nil) async {
        guard !isSaving, let store else { return }
        do {
            var web = CanvasDocument(title: "Teia \(summaries.filter { $0.kind == .web }.count + 1)", kind: .web)
            if let id, let summary = summaries.first(where: { $0.id == id && $0.kind == .note }) {
                web = try CommandEngine.applying(TeiaEngine.addNotes([.init(id: summary.id, title: summary.title, createdAt: summary.createdAt)], to: web), to: web)
            }
            document = try await store.create(web)
            try await refresh()
        } catch { self.error = String(describing: error) }
    }

    func addNote(_ summary: DocumentSummary) {
        guard let document else { return }
        do { enqueue(try TeiaEngine.addNotes([.init(id: summary.id, title: summary.title, createdAt: summary.createdAt)], to: document)) }
        catch { self.error = String(describing: error) }
    }

    func enqueue(_ commands: [DocumentCommand]) {
        guard !commands.isEmpty, !writeFailed, let document else { return }
        do {
            var optimistic = try CommandEngine.applying(commands, to: document)
            guard document.revision < Int64.max else { throw DocumentError.invalid("Revision exhausted") }
            optimistic.revision = document.revision + 1
            optimistic.updatedAt = max(Date(), document.updatedAt)
            self.document = optimistic
        } catch { self.error = String(describing: error); return }
        pending.append((document.id, document.revision, commands))
        guard !isSaving else { return }
        isSaving = true
        Task { await drain() }
    }

    private func drain() async {
        defer { isSaving = false }
        guard let store else { return }
        while !pending.isEmpty {
            let (id, expectedRevision, commands) = pending.removeFirst()
            do {
                guard document?.id == id else { throw DocumentError.invalid("Editor changed during save") }
                let saved = try await store.execute(commands, documentID: id, expectedRevision: expectedRevision)
                if document?.revision == saved.revision { document = saved }
            } catch {
                // Stop on a failed commit; do not pretend subsequent edits were saved.
                writeFailed = true; pending.removeAll(); self.error = "Gravação interrompida. Copie o texto em edição antes de fechar. \(error)"
                return
            }
        }
        do { try await refresh() } catch { self.error = String(describing: error) }
    }

    func history(undo: Bool) async {
        guard !isSaving, !writeFailed, let document, let store else { return }
        do {
            self.document = try await (undo ? store.undo(documentID: document.id, expectedRevision: document.revision) : store.redo(documentID: document.id, expectedRevision: document.revision))
            try await refresh()
        } catch { self.error = String(describing: error) }
    }

    func image(_ hash: String) -> UIImage? {
        if let cached = images[hash] { return cached }
        guard let url = directory?.appendingPathComponent("assets").appendingPathComponent(hash),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 2048, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { return nil }
        let image = UIImage(cgImage: thumbnail); images[hash] = image; return image
    }

    func importImage(_ item: PhotosPickerItem) async {
        guard let directory, let document else { return }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else { throw DocumentError.invalid("Could not load image") }
            guard let current = self.document, current.id == document.id else { return }
            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            let destination = directory.appendingPathComponent("assets").appendingPathComponent(hash)
            if !FileManager.default.fileExists(atPath: destination.path) { try data.write(to: destination, options: .atomic) }
            let metadata = Asset(hash: hash, mediaType: item.supportedContentTypes.first?.preferredMIMEType ?? "application/octet-stream", byteCount: Int64(data.count))
            let order = (current.blocks.filter { $0.parentID == nil }.map(\.order).max() ?? -1) + 1
            let decoded = image(hash)
            let aspect = Double((decoded?.size.height ?? 200) / max(1, decoded?.size.width ?? 240))
            let block = CanvasBlock(order: order, layout: .init(mode: .absolute, frame: .init(x: 100, y: 150, width: 240, height: 240 * aspect)), content: .image(.init(hash: hash)))
            enqueue((current.assets.contains(where: { $0.hash == hash }) ? [] : [.registerAsset(metadata)]) + [.insertBlock(block)])
        } catch { self.error = String(describing: error) }
    }

    private func preview(_ note: CanvasDocument) -> UIImage {
        let text = note.blocks.compactMap { block -> String? in if case .text(let text) = block.content { text.plainText } else { nil } }.joined(separator: "\n")
        return UIGraphicsImageRenderer(size: CGSize(width: 240, height: 130)).image { ctx in
            UIColor.white.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 240, height: 130))
            (text as NSString).draw(in: CGRect(x: 10, y: 10, width: 220, height: 110), withAttributes: [.font: UIFont.systemFont(ofSize: 12), .foregroundColor: UIColor.black])
        }
    }
}

struct DemoScreen: View {
    @Bindable var model: DemoModel
    @State private var tool = CanvasTool.select
    @State private var showPage = false
    @State private var equation = "x² - 5x + 6 = 0"
    @State private var showEquation = false
    @State private var photo: PhotosPickerItem?
    var body: some View {
        NavigationSplitView {
            List {
                Section {
                    Button("Nova nota", systemImage: "plus") { Task { await model.createNote() } }
                    Button("Nova Teia", systemImage: "point.3.connected.trianglepath.dotted") { Task { await model.createWeb() } }
                    ForEach(model.summaries) { summary in
                        VStack(alignment: .leading) {
                            Button { Task { await model.open(summary.id) } } label: {
                                VStack(alignment: .leading) {
                                    if let preview = model.noteMetadata[summary.id]?.preview { Image(uiImage: preview).resizable().scaledToFit().frame(height: 70) }
                                    Text(summary.title).font(.headline)
                                    Text(summary.createdAt, style: .date).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            if summary.kind == .note { Button("Teia") { Task { await model.createWeb(including: summary.id) } }.font(.caption) }
                        }
                    }
                } header: { Text("Todas as notas e Teias") }
            }.navigationTitle("Got It!")
            .disabled(model.isSaving)
        } detail: {
            if let document = model.document {
                VStack(spacing: 0) {
                    if model.writeFailed { Text("Alterações não estão sendo salvas").foregroundStyle(.red).padding(8) }
                    CanvasEditor(document: document, tool: tool, image: model.image,
                        note: { model.noteMetadata[$0] }, onCommands: model.enqueue,
                        onOpenNote: { id in Task { await model.open(id) } }, onError: { model.error = String(describing: $0) })
                }
                .navigationTitle(document.title)
                .toolbar {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button { Task { await model.history(undo: true) } } label: { Image(systemName: "arrow.uturn.backward") }.disabled(model.isSaving)
                        Button { Task { await model.history(undo: false) } } label: { Image(systemName: "arrow.uturn.forward") }.disabled(model.isSaving)
                        Menu {
                            Picker("Ferramenta", selection: $tool) { Text("Selecionar / texto").tag(CanvasTool.select); Text("Desenhar").tag(CanvasTool.draw) }
                            Button("Tamanho e opções do canvas") { showPage = true }
                            PhotosPicker(selection: $photo, matching: .images) { Text("Adicionar imagem") }
                            if document.kind == .note { Button("Teia desta nota") { Task { await model.createWeb(including: document.id) } } }
                            else {
                                Menu("Adicionar nota à Teia") { ForEach(model.summaries.filter { $0.kind == .note }) { summary in Button(summary.title) { model.addNote(summary) } } }
                            }
                            if document.canvas.solveEquations { Button("Resolver equação digitada") { showEquation = true } }
                        } label: { Image(systemName: "ellipsis.circle") }
                    }
                }
                .sheet(isPresented: $showPage) { PageOptions(settings: document.canvas) { model.enqueue([.setCanvasSettings($0)]) } }
                .alert("Equação de uma incógnita", isPresented: $showEquation) {
                    TextField("Ex.: x² - 5x + 6 = 0", text: $equation)
                    Button("Resolver") { solveEquation(document) }
                    Button("Cancelar", role: .cancel) { }
                } message: { Text("Nesta demonstração, digite ou corrija a expressão. O reconhecimento de equações manuscritas ainda não está conectado.") }
            } else { ContentUnavailableView("Got It!", systemImage: "note.text", description: Text("Crie ou selecione uma nota.")) }
        }
        .onChange(of: photo) { _, item in if let item { Task { await model.importImage(item) }; photo = nil } }
        .alert("Aviso", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK", role: .cancel) { model.error = nil }
        } message: { Text(model.error ?? "") }
    }
    private func solveEquation(_ document: CanvasDocument) {
        do {
            let result = try EquationSolver.solve(equation)
            let output: String
            switch result {
            case .realRoots(let roots): output = roots.map { "x = \($0.formatted())" }.joined(separator: "; ")
            case .noRealRoots: output = "Sem solução real"
            case .allRealNumbers: output = "Todo número real é solução"
            }
            let order = (document.blocks.filter { $0.parentID == nil }.map(\.order).max() ?? -1) + 1
            model.enqueue([.insertBlock(.init(order: order, layout: .init(mode: .absolute, frame: .init(x: 24, y: 24, width: 400, height: 100)), content: .text(.init("\(equation)\n\(output)"))))])
        } catch { model.error = "Expressão não suportada ou ambígua. \(error)" }
    }
}

struct PageOptions: View {
    @Environment(\.dismiss) private var dismiss
    @State var settings: CanvasSettings
    let onSave: (CanvasSettings) -> Void
    @State private var width = ""
    @State private var height = ""
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                Picker("Unidade", selection: $settings.displayUnit) { Text("cm").tag(CanvasUnit.centimeters); Text("in").tag(CanvasUnit.inches); Text("px (96 ppi)").tag(CanvasUnit.pixels) }
                    .onChange(of: settings.displayUnit) { _, _ in loadSize() }
                TextField("Largura", text: $width).keyboardType(.decimalPad)
                TextField("Altura", text: $height).keyboardType(.decimalPad)
                Button("A4") { settings.size = .a4; loadSize() }
                Toggle("Texto contorna objetos", isOn: $settings.textAvoidsObjects)
                Toggle("Reconhecer diagramas", isOn: $settings.recognizeDiagrams)
                Toggle("Resolver equações", isOn: $settings.solveEquations)
                if let error { Text(error).foregroundStyle(.red) }
            }.navigationTitle("Canvas")
                .toolbar { Button("Aplicar") { save() } }
                .onAppear { loadSize() }
        }
    }
    private func loadSize() {
        guard let dimensions = try? settings.size.dimensions(in: settings.displayUnit, pixelsPerInch: settings.pixelsPerInch) else { return }
        width = String(format: "%.3f", dimensions.width); height = String(format: "%.3f", dimensions.height)
    }
    private func save() {
        do {
            guard let width = Double(width.replacingOccurrences(of: ",", with: ".")), let height = Double(height.replacingOccurrences(of: ",", with: ".")) else { throw DocumentError.invalid("Dimensões inválidas") }
            settings.size = try .init(width: width, height: height, unit: settings.displayUnit, pixelsPerInch: settings.pixelsPerInch)
            onSave(settings); dismiss()
        } catch { self.error = String(describing: error) }
    }
}
