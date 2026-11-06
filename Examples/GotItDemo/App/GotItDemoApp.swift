import SwiftUI
import PhotosUI
import CryptoKit
import ImageIO
import PencilKit
import PDFKit
import UniformTypeIdentifiers
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
    var selectedPageID: UUID?
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
            var root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("GotItDemo")
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
                root = root.deletingLastPathComponent().appendingPathComponent("GotItUITests")
                if ProcessInfo.processInfo.arguments.contains("--reset-test-data"), FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
            }
            #endif
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
        if let document, !document.pages.contains(where: { $0.id == selectedPageID }) { selectedPageID = document.pages.first?.id }
        for summary in summaries where summary.kind == .note {
            let note = try await store.load(summary.id)
            noteMetadata[summary.id] = .init(title: summary.title, createdAt: summary.createdAt, preview: preview(note))
        }
    }

    func open(_ id: UUID) async {
        guard !isSaving, let store else { return }
        do { document = try await store.load(id); selectedPageID = document?.pages.first?.id }
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
        if let bytes = assetData(hash), let pdf = PDFDocument(data: bytes), let page = pdf.page(at: 0) {
            let image = page.thumbnail(of: CGSize(width: 600, height: 850), for: .mediaBox)
            images[hash] = image; return image
        }
        guard let url = directory?.appendingPathComponent("assets").appendingPathComponent(hash),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 2048, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { return nil }
        let image = UIImage(cgImage: thumbnail); images[hash] = image; return image
    }

    var activePageID: UUID? { document?.pages.first(where: { $0.id == selectedPageID })?.id ?? document?.pages.first?.id }

    func addPage() {
        guard let document else { return }
        let page = CanvasPage(title: "Página \(document.pages.count + 1)")
        enqueue([.appendPage(page)])
        if self.document?.pages.contains(where: { $0.id == page.id }) == true { selectedPageID = page.id }
    }

    func enqueue(_ commands: [DocumentCommand], pageID: UUID, documentID: UUID) {
        guard let document, document.id == documentID else { return }
        do { enqueue(try document.commands(commands, on: pageID)) }
        catch { self.error = String(describing: error) }
    }

    func assetData(_ hash: String) -> Data? {
        guard let directory else { return nil }
        return try? Data(contentsOf: directory.appendingPathComponent("assets").appendingPathComponent(hash))
    }

    private func storeAsset(_ data: Data, mediaType: String) throws -> Asset {
        guard let directory else { throw DocumentError.invalid("Storage unavailable") }
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let destination = directory.appendingPathComponent("assets").appendingPathComponent(hash)
        if !FileManager.default.fileExists(atPath: destination.path) { try data.write(to: destination, options: .atomic) }
        return Asset(hash: hash, mediaType: mediaType, byteCount: Int64(data.count))
    }

    func saveDrawing(_ data: Data, extra: [DocumentCommand], pageID: UUID, documentID: UUID) {
        guard let document, document.id == documentID, !writeFailed else { return }
        do {
            let drawing = try PKDrawing(data: data)
            let existing = document.blocks.first { block in
                if case .drawing = block.content { return document.pageID(for: block.id) == pageID }; return false
            }
            var commands = extra
            if drawing.strokes.isEmpty {
                if let existing { commands.append(.removeSubtree(existing.id)) }
            } else {
                let asset = try storeAsset(data, mediaType: "application/x-pencilkit")
                if !document.assets.contains(where: { $0.hash == asset.hash }) { commands.append(.registerAsset(asset)) }
                var block = existing ?? CanvasBlock(layout: .init(mode: .absolute, frame: .init(x: 0, y: 0, width: document.canvas.size.width, height: document.canvas.size.height), zIndex: 1000), content: .drawing(.init(hash: asset.hash)), presentation: .init(wrap: .none))
                block.content = .drawing(.init(hash: asset.hash))
                commands.append(existing == nil ? .insertBlock(block) : .replaceBlock(block))
            }
            enqueue(commands, pageID: pageID, documentID: documentID)
        } catch { self.error = String(describing: error) }
    }

    func importImage(_ item: PhotosPickerItem, sticker: Bool, pageID: UUID, documentID: UUID) async {
        do {
            guard let data = try await item.loadTransferable(type: Data.self),
                  CGImageSourceCreateWithData(data as CFData, nil) != nil else { throw DocumentError.invalid("Could not load image") }
            guard let current = document, current.id == documentID, current.pages.contains(where: { $0.id == pageID }) else { return }
            let asset = try storeAsset(data, mediaType: item.supportedContentTypes.first?.preferredMIMEType ?? "application/octet-stream")
            let decoded = image(asset.hash)
            let aspect = Double((decoded?.size.height ?? 200) / max(1, decoded?.size.width ?? 240))
            let width = min(240, current.canvas.size.width * 0.6)
            let block = CanvasBlock(layout: .init(mode: .absolute, frame: .init(x: 24, y: 80, width: width, height: width * aspect)), content: sticker ? .sticker(.init(hash: asset.hash)) : .image(.init(hash: asset.hash)))
            enqueue((current.assets.contains(where: { $0.hash == asset.hash }) ? [] : [.registerAsset(asset)]) + [.insertBlock(block)], pageID: pageID, documentID: documentID)
        } catch { self.error = String(describing: error) }
    }

    func importPDF(_ url: URL, pageID: UUID, documentID: UUID) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            guard let document, document.id == documentID else { return }
            let data = try Data(contentsOf: url)
            guard let pdf = PDFDocument(data: data), pdf.pageCount > 0, !pdf.isLocked else { throw DocumentError.invalid("PDF vazio, protegido ou inválido") }
            let asset = try storeAsset(data, mediaType: "application/pdf")
            let block = CanvasBlock(layout: .init(mode: .absolute, frame: .init(x: 24, y: 80, width: 240, height: 340)), content: .pdf(.init(hash: asset.hash, caption: url.lastPathComponent)))
            enqueue((document.assets.contains(where: { $0.hash == asset.hash }) ? [] : [.registerAsset(asset)]) + [.insertBlock(block)], pageID: pageID, documentID: documentID)
        } catch { self.error = String(describing: error) }
    }

    func pagePreview(_ page: CanvasDocument) -> UIImage {
        PagePreview.image(document: page, asset: image, drawingData: assetData)
    }

    private func preview(_ note: CanvasDocument) -> UIImage {
        let first = note.pages.first.flatMap { try? note.pageDocument($0.id) } ?? note
        return PagePreview.image(document: first, width: 120, asset: image, drawingData: assetData)
    }
}

struct DemoScreen: View {
    @Bindable var model: DemoModel
    @State private var visibility = NavigationSplitViewVisibility.detailOnly
    @State private var showPage = false
    @State private var equation = "x² - 5x + 6 = 0"
    @State private var showEquation = false
    var body: some View {
        NavigationSplitView(columnVisibility: $visibility) {
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
                    EditorWorkspace(model: model, document: document)

                }
                .navigationTitle(document.title)
                .toolbar {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button { Task { await model.history(undo: true) } } label: { Image(systemName: "arrow.uturn.backward") }.disabled(model.isSaving)
                        Button { Task { await model.history(undo: false) } } label: { Image(systemName: "arrow.uturn.forward") }.disabled(model.isSaving)
                        Menu {
                            Button("Tamanho e opções do canvas") { showPage = true }
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
            model.enqueue([.insertBlock(.init(order: order, layout: .init(mode: .absolute, frame: .init(x: 24, y: 24, width: 400, height: 100)), content: .text(.init("\(equation)\n\(output)"))))], pageID: model.activePageID ?? document.id, documentID: document.id)
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
