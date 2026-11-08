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
struct GotItAppApp: App {
    @State private var model = AppModel()
    var body: some Scene { WindowGroup { AppScreen(model: model).task { await model.start() } } }
}

@Observable @MainActor
final class AppModel {
    var document: CanvasDocument?
    var selectedPageID: UUID?
    var summaries: [DocumentSummary] = []
    private var previewRevisions: [UUID: Int64] = [:]
    private var lastPreviewTime = Date.distantPast
    var noteMetadata: [UUID: NoteCardPresentation] = [:]
    /// Teias a note was opened from, most recent last: "back" returns there before the list.
    var returnStack: [UUID] = []
    var error: String?
    var isSaving = false
    var writeFailed = false
    private var store: SQLiteStore?
    private var directory: URL?
    /// Edits on screen that SQLite has not committed yet, in order.
    private var pending: [PendingEdit] = []
    /// Write-ahead copy of `pending` on disk, replayed at the next start if the app is closed or
    /// killed first. Without it (unreadable or unwritable file) editing goes on, unprotected.
    private var journal: PendingEditJournal?
    private var journalWarned = false
    /// Committed edits whose receipts can be dropped once the queue is empty.
    private var committedOperations: [UUID] = []
    #if DEBUG
    /// UI tests: never commit, to check what a killed app recovers.
    private var holdSaves = false
    #endif
    private var nextAssetCleanup = Date.distantPast
    private let images = NSCache<NSString, UIImage>()

    func start() async {
        guard store == nil else { return }
        images.totalCostLimit = 32 * 1024 * 1024; images.countLimit = 32
        do {
            var root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("GotItDemo")
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
                root = root.deletingLastPathComponent().appendingPathComponent("GotItUITests")
                if ProcessInfo.processInfo.arguments.contains("--reset-test-data"), FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
                holdSaves = ProcessInfo.processInfo.arguments.contains("--hold-saves")
            }
            #endif
            try FileManager.default.createDirectory(at: root.appendingPathComponent("assets"), withIntermediateDirectories: true)
            directory = root
            let repository = try SQLiteStore(url: root.appendingPathComponent("notes.sqlite"))
            store = repository
            await recoverPendingEdits(root: root, store: repository)
            try await collectUnusedAssets()
            try await refresh()
            if summaries.isEmpty { await createNote() }
            else if let first = summaries.first { await open(first.id) }
        } catch { self.error = String(describing: error) }
    }

    /// Re-applies edits that were on screen but not yet saved when the app last stopped. Edits that
    /// cannot be applied are moved to a separate file, never dropped and never retried forever.
    private func recoverPendingEdits(root: URL, store: SQLiteStore) async {
        let url = root.appendingPathComponent("pending-edits.jsonl")
        let opened: PendingEditJournal
        do { opened = try PendingEditJournal(url: url) }
        catch {
            let kept = root.appendingPathComponent("pending-edits-unreadable-\(Int(Date().timeIntervalSince1970)).jsonl")
            try? FileManager.default.moveItem(at: url, to: kept)
            self.error = "A fila de recuperação estava ilegível e foi guardada à parte (\(kept.lastPathComponent)). As edições novas são salvas normalmente."
            guard let fresh = try? PendingEditJournal(url: url) else { return }
            opened = fresh
        }
        journal = opened
        guard !opened.entries.isEmpty else { return }
        let count = opened.entries.count
        do { try await opened.replay(into: store) }
        catch {
            let kept = try? opened.quarantine()
            self.error = "\(count) edição(ões) feitas pouco antes de o app fechar não puderam ser reaplicadas e foram guardadas em \(kept?.lastPathComponent ?? "um arquivo à parte"). \(error)"
        }
    }

    private func journalProblem(_ error: Error) {
        guard !journalWarned else { return }
        journalWarned = true
        self.error = "Não foi possível gravar a fila de recuperação; as edições continuam sendo salvas, mas sem proteção se o app fechar de repente. \(error)"
    }

    func refresh() async throws {
        guard let store else { return }
        summaries = try await store.listDocuments()
        if let document, !document.pages.contains(where: { $0.id == selectedPageID }) { selectedPageID = document.pages.first?.id }
        let updatePreviews = Date().timeIntervalSince(lastPreviewTime) > 2
        if updatePreviews { lastPreviewTime = Date() }
        for summary in summaries where summary.kind == .note {
            guard previewRevisions[summary.id] != summary.revision, updatePreviews || noteMetadata[summary.id] == nil else { continue }
            let note = try await store.load(summary.id)
            noteMetadata[summary.id] = .init(title: summary.title, createdAt: summary.createdAt, preview: preview(note))
            previewRevisions[summary.id] = summary.revision
        }
    }

    /// Opens a note or Teia. `returningTo` is the Teia it was opened from; opening from the list
    /// (no origin) starts over.
    func open(_ id: UUID, returningTo origin: UUID? = nil) async {
        guard !isSaving, let store else { return }
        do {
            let loaded = try await store.load(id)
            if let origin, origin != id { returnStack.append(origin) } else if origin == nil { returnStack.removeAll() }
            document = loaded; selectedPageID = loaded.pages.first?.id
        }
        catch { self.error = String(describing: error) }
    }

    /// Back to the Teia this note was opened from.
    func goBack() async {
        guard !isSaving, let store, let origin = returnStack.last else { return }
        do {
            let loaded = try await store.load(origin)
            returnStack.removeLast()
            document = loaded; selectedPageID = loaded.pages.first?.id
        } catch { returnStack.removeLast(); self.error = String(describing: error) }
    }
    var returnTitle: String? {
        returnStack.last.map { id in summaries.first { $0.id == id }?.title ?? "Teia" }
    }

    func createNote() async {
        guard !isSaving, let store else { return }
        returnStack.removeAll()
        do {
            document = try await store.create(.init(title: "Nota \(summaries.filter { $0.kind == .note }.count + 1)", defaultStyle: .init(fontSize: 18)))
            try await refresh()
        } catch { self.error = String(describing: error) }
    }

    func createWeb(including id: UUID? = nil) async {
        guard !isSaving, let store else { return }
        returnStack.removeAll()
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

    func enqueue(_ commands: [DocumentCommand], historyGroup: String? = nil) {
        guard !commands.isEmpty, !writeFailed, let document else { return }
        do {
            var optimistic = try CommandEngine.applying(commands, to: document)
            guard document.revision < Int64.max else { throw DocumentError.invalid("Revision exhausted") }
            optimistic.revision = document.revision + 1
            optimistic.updatedAt = max(Date(), document.updatedAt)
            let edit = PendingEdit(documentID: document.id, expectedRevision: document.revision, commands: commands, historyGroup: historyGroup)
            // Written ahead of showing it: if the app is closed now, the next start re-applies it.
            if let journal { do { try journal.append(edit) } catch { journalProblem(error) } }
            self.document = optimistic
            pending.append(edit)
        } catch { self.error = String(describing: error); return }
        guard !isSaving else { return }
        isSaving = true
        Task { await drain() }
    }

    private func drain() async {
        defer { isSaving = false }
        guard let store else { return }
        #if DEBUG
        if holdSaves { return }
        #endif
        while !pending.isEmpty {
            let edit = pending.removeFirst()
            do {
                guard document?.id == edit.documentID else { throw DocumentError.invalid("Editor changed during save") }
                let saved = try await store.execute(edit.commands, documentID: edit.documentID, expectedRevision: edit.expectedRevision,
                                                    historyGroup: edit.historyGroup, operationID: journal == nil ? nil : edit.id)
                if document?.revision == saved.revision { document = saved }
                if let journal {
                    do { try journal.remove(edit.id) } catch { journalProblem(error) }
                    committedOperations.append(edit.id)
                }
            } catch {
                // Stop on a failed commit; do not pretend subsequent edits were saved. What is still
                // in the journal is re-applied (or set aside) at the next start.
                writeFailed = true; pending.removeAll()
                self.error = journal == nil
                    ? "Gravação interrompida. Copie o texto em edição antes de fechar. \(error)"
                    : "Gravação interrompida. As edições ainda não gravadas ficaram na fila de recuperação e serão reaplicadas quando o app abrir de novo. \(error)"
                return
            }
        }
        // Receipts only matter while their edit is in the journal; drop them in one write.
        if !committedOperations.isEmpty {
            let done = committedOperations; committedOperations = []
            try? await store.acknowledgeOperations(done)
        }
        do { try await refresh(); try await collectUnusedAssets() } catch { self.error = String(describing: error) }
    }

    // A grace period protects files being imported while an awaited database read yields.
    // Startup and idle checkpoints reclaim orphans left by crashes or evicted history.
    private func collectUnusedAssets() async throws {
        guard let store, let directory, Date() >= nextAssetCleanup else { return }
        nextAssetCleanup = Date().addingTimeInterval(300)
        let root = directory.appendingPathComponent("assets")
        let candidates = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey])
            .filter { url in
                let name = url.lastPathComponent
                return name.count == 64 && name.allSatisfy { $0.isHexDigit } &&
                    ((try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantFuture) < Date().addingTimeInterval(-86400)
            }
        guard !candidates.isEmpty else { return }
        let retained = try await store.retainedAssetHashes()
        for url in candidates where !retained.contains(url.lastPathComponent) {
            try FileManager.default.removeItem(at: url); images.removeObject(forKey: url.lastPathComponent as NSString)
        }
    }

    func history(undo: Bool) async {
        guard !isSaving, !writeFailed, let document, let store else { return }
        do {
            self.document = try await (undo ? store.undo(documentID: document.id, expectedRevision: document.revision) : store.redo(documentID: document.id, expectedRevision: document.revision))
            try await refresh()
        } catch { self.error = String(describing: error) }
    }

    func image(_ hash: String) -> UIImage? {
        if let cached = images.object(forKey: hash as NSString) { return cached }
        if let bytes = assetData(hash), let pdf = PDFDocument(data: bytes), let page = pdf.page(at: 0) {
            let image = page.thumbnail(of: CGSize(width: 600, height: 850), for: .mediaBox)
            images.setObject(image, forKey: hash as NSString, cost: Int(image.size.width * image.size.height * 4)); return image
        }
        guard let url = directory?.appendingPathComponent("assets").appendingPathComponent(hash),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 2048, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { return nil }
        let image = UIImage(cgImage: thumbnail); images.setObject(image, forKey: hash as NSString, cost: Int(image.size.width * image.size.height * 4)); return image
    }

    var activePageID: UUID? { document?.pages.first(where: { $0.id == selectedPageID })?.id ?? document?.pages.first?.id }

    func addPage() {
        guard let document else { return }
        let page = CanvasPage(title: "Página \(document.pages.count + 1)")
        enqueue([.appendPage(page)])
        if self.document?.pages.contains(where: { $0.id == page.id }) == true { selectedPageID = page.id }
    }

    func enqueue(_ commands: [DocumentCommand], pageID: UUID, documentID: UUID, historyGroup: String? = nil) {
        guard let document, document.id == documentID else { return }
        do {
            var all = try document.commands(commands, on: pageID)
            all += reflowCommands(after: all, in: document)
            enqueue(all, historyGroup: historyGroup)
        }
        catch { self.error = String(describing: error) }
    }

    func enqueueReflowing(_ commands: [DocumentCommand]) {
        guard let document else { return }
        enqueue(commands + reflowCommands(after: commands, in: document))
    }

    /// Moving, resizing, inserting or removing an object that text wraps around redistributes the
    /// affected stories in the same batch, so one undo restores both the object and the text.
    /// A story that cannot be laid out keeps its previous text; the edit itself is still applied.
    private func reflowCommands(after commands: [DocumentCommand], in document: CanvasDocument) -> [DocumentCommand] {
        guard commands.contains(where: {
            switch $0 { case .insertBlock, .replaceBlock, .removeSubtree, .setCanvasSettings: return true; default: return false }
        }), var working = try? CommandEngine.applying(commands, to: document) else { return [] }
        var extra: [DocumentCommand] = []
        var stories = working.storiesAffectedByObstacleChanges(since: document)
        for story in working.storiesWithTextChanges(since: document) where !stories.contains(story) { stories.append(story) }
        for story in stories {
            guard let first = working.textFlowFragments(story: story).first else { continue }
            do {
                let result = try TextPagination.reflow(first, in: working, selection: NSRange(location: 0, length: 0))
                working = try CommandEngine.applying(result.commands, to: working)
                extra += result.commands
            } catch { self.error = String(describing: error) }
        }
        return extra
    }

    func editText(_ block: CanvasBlock, group: String?, selection: NSRange) -> TextFlowFocus? {
        guard let document else { return nil }
        guard block.textFlowID != nil, block.parentID == nil else {
            enqueue([.replaceBlock(block)], historyGroup: group); return nil
        }
        do {
            let result = try TextPagination.reflow(block, in: document, selection: selection)
            enqueue(result.commands, historyGroup: group)
            if !writeFailed { selectedPageID = result.focus.pageID }
            return result.focus
        } catch {
            // Preserve the entered text even if a tiny/fully obstructed area cannot paginate.
            enqueue([.replaceBlock(block)], historyGroup: group)
            self.error = String(describing: error); return nil
        }
    }

    /// Backspace at the start of a continuation box removes the last character of the previous
    /// box with text (on an earlier page) and reflows the story; the caret goes there.
    func backspaceAcrossFragments(_ blockID: UUID, group: String?) -> TextFlowFocus? {
        guard let document, let merge = document.backspaceAcrossFragments(at: blockID) else { return nil }
        return editText(merge.replacement, group: group, selection: NSRange(location: merge.caret, length: 0))
    }

    func assetURL(_ hash: String) -> URL? { directory?.appendingPathComponent("assets").appendingPathComponent(hash) }

    func savePDF(_ data: Data, blockID: UUID, documentID: UUID) throws {
        guard !writeFailed, let document, document.id == documentID,
              var block = document.blocks.first(where: { $0.id == blockID }), case .pdf(let ref) = block.content else { throw DocumentError.invalid("PDF indisponível") }
        let asset = try storeAsset(data, mediaType: "application/pdf")
        guard asset.hash != ref.hash else { return }
        block.content = .pdf(.init(hash: asset.hash, caption: ref.caption))
        var commands: [DocumentCommand] = document.assets.contains(where: { $0.hash == asset.hash }) ? [] : [.registerAsset(asset)]
        commands.append(.replaceBlock(block))
        if !document.blocks.contains(where: { $0.id != blockID && $0.content.assetHash == ref.hash }) { commands.append(.unregisterAsset(ref.hash)) }
        enqueue(commands)
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
            if let oldHash = existing?.content.assetHash,
               !document.blocks.contains(where: { $0.id != existing?.id && $0.content.assetHash == oldHash }),
               !commands.contains(where: { if case .replaceBlock(let b) = $0 { return b.content.assetHash == oldHash }; return false }) {
                commands.append(.unregisterAsset(oldHash))
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

    /// Built-in stickers (rendered emoji): no picker, inserted at a fixed spot and selected.
    func insertSticker(png data: Data, pageID: UUID, documentID: UUID) {
        do {
            guard let current = document, current.id == documentID, current.pages.contains(where: { $0.id == pageID }) else { return }
            let asset = try storeAsset(data, mediaType: "image/png")
            let block = CanvasBlock(layout: .init(mode: .absolute, frame: .init(x: 40, y: 80, width: 120, height: 120)),
                                    content: .sticker(.init(hash: asset.hash)), presentation: .init(wrap: .none))
            enqueue((current.assets.contains(where: { $0.hash == asset.hash }) ? [] : [.registerAsset(asset)]) + [.insertBlock(block)],
                    pageID: pageID, documentID: documentID)
        } catch { self.error = String(describing: error) }
    }

    /// Drawn stickers: a yellow post-it with a text box, or a calendar showing today. Inserted at a
    /// fixed spot of the page and selected, like the emoji stickers.
    func insertStickyNote(pageID: UUID, documentID: UUID) {
        guard let current = document, current.id == documentID, current.pages.contains(where: { $0.id == pageID }) else { return }
        enqueue(Stickers.stickyNote(at: .init(x: 40, y: 80), order: nextRootOrder(in: current)), pageID: pageID, documentID: documentID)
    }
    func insertCalendar(pageID: UUID, documentID: UUID) {
        guard let current = document, current.id == documentID, current.pages.contains(where: { $0.id == pageID }) else { return }
        enqueue(Stickers.calendar(at: .init(x: 40, y: 80), order: nextRootOrder(in: current)), pageID: pageID, documentID: documentID)
    }
    private func nextRootOrder(in document: CanvasDocument) -> Int {
        (document.blocks.filter { $0.parentID == nil }.map(\.order).max() ?? -1) + 1
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

    /// The note's strokes as JSON (ink left as ink, and the original strokes of shapes and
    /// connectors made from ink), so recognition can be tuned on the user's own handwriting.
    func exportInk(of document: CanvasDocument) throws -> URL {
        var strokes: [InkSampleFile.Stroke] = []
        func rounded(_ value: Double) -> Double { (value * 10).rounded() / 10 }
        for (index, page) in document.pages.enumerated() {
            let projection = try document.pageDocument(page.id)
            for block in projection.blocks {
                switch block.content {
                case .drawing(let ref):
                    guard let data = assetData(ref.hash) else { continue }
                    for stroke in try PKDrawing(data: data).strokes {
                        let points = stroke.path.map { point -> [Double] in
                            let location = point.location.applying(stroke.transform)
                            return [rounded(location.x), rounded(location.y), (point.timeOffset * 1000).rounded() / 1000]
                        }
                        strokes.append(.init(kind: "tinta", page: index + 1, points: points))
                    }
                case .shape(let shape):
                    guard let original = shape.originalStroke else { continue }
                    strokes.append(.init(kind: shape.kind.rawValue, page: index + 1, points: original.points.map { [rounded($0.x), rounded($0.y), 0] }))
                default: continue
                }
            }
            for relation in projection.relations {
                guard let original = relation.originalStroke else { continue }
                strokes.append(.init(kind: "conector", page: index + 1, points: original.points.map { [rounded($0.x), rounded($0.y), 0] }))
            }
        }
        guard !strokes.isEmpty else { throw DocumentError.invalid("Esta nota não tem traços desenhados.") }
        var system = utsname(); uname(&system)
        let machine = withUnsafeBytes(of: &system.machine) { raw in String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self) }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let file = InkSampleFile(app: "Got It! \(version)", device: "\(machine), iOS \(UIDevice.current.systemVersion)", exportedAt: Date(), strokes: strokes)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let name = document.title.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: "-")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("GotIt-tracos-\(name.isEmpty ? "nota" : name).json")
        try encoder.encode(file).write(to: url, options: .atomic)
        return url
    }

    func pagePreview(_ page: CanvasDocument) -> UIImage {
        PagePreview.image(document: page, asset: image, drawingData: assetData)
    }

    private func preview(_ note: CanvasDocument) -> UIImage {
        let first = note.pages.first.flatMap { try? note.pageDocument($0.id) } ?? note
        return PagePreview.image(document: first, width: 120, asset: image, drawingData: assetData)
    }
}

struct AppScreen: View {
    @Bindable var model: AppModel
    @State private var visibility = NavigationSplitViewVisibility.detailOnly
    @State private var preferredColumn = NavigationSplitViewColumn.detail
    @State private var showPage = false
    @State private var equation = "x² - 5x + 6 = 0"
    @State private var showEquation = false
    @State private var showDiagnostics = false
    @State private var sharing: ShareFile?
    var body: some View {
        NavigationSplitView(columnVisibility: $visibility, preferredCompactColumn: $preferredColumn) {
            List {
                Section {
                    Button("Nova nota", systemImage: "plus") { Task { await model.createNote(); preferredColumn = .detail } }
                    Button("Nova Teia", systemImage: "point.3.connected.trianglepath.dotted") { Task { await model.createWeb(); preferredColumn = .detail } }
                    ForEach(model.summaries) { summary in
                        // A List row with two buttons fires both on a single tap (opening a note
                        // also created a Teia). One button per row; Teia is in the context menu.
                        Button { Task { await model.open(summary.id); preferredColumn = .detail } } label: {
                            VStack(alignment: .leading) {
                                if let preview = model.noteMetadata[summary.id]?.preview { Image(uiImage: preview).resizable().scaledToFit().frame(height: 70) }
                                Text(summary.title).font(.headline)
                                Text(summary.createdAt, style: .date).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .contextMenu {
                            if summary.kind == .note {
                                Button("Criar Teia com esta nota", systemImage: "point.3.connected.trianglepath.dotted") {
                                    Task { await model.createWeb(including: summary.id); preferredColumn = .detail }
                                }
                            }
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
                .navigationBarTitleDisplayMode(.inline)
                // Opened from a Teia: "back" returns to it first, then to the list.
                .navigationBarBackButtonHidden(model.returnTitle != nil)
                .toolbar {
                    if let title = model.returnTitle {
                        ToolbarItem(placement: .topBarLeading) {
                            Button { Task { await model.goBack() } } label: {
                                HStack(spacing: 4) { Image(systemName: "chevron.backward").fontWeight(.semibold); Text(title).lineLimit(1) }
                            }
                            .accessibilityLabel("Voltar para \(title)").accessibilityIdentifier("backToTeia")
                        }
                    }
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
                            Divider()
                            Button("Exportar traços desta nota", systemImage: "scribble") {
                                do { sharing = ShareFile(url: try model.exportInk(of: document)) }
                                catch let DocumentError.invalid(text) { model.error = text }
                                catch { model.error = String(describing: error) }
                            }
                            Button("Medir desempenho do aparelho", systemImage: "speedometer") { showDiagnostics = true }
                        } label: { Image(systemName: "ellipsis.circle") }.accessibilityIdentifier("documentOptions")
                    }
                }
                .sheet(isPresented: $showPage) { PageOptions(settings: document.canvas) { model.enqueueReflowing([.setCanvasSettings($0)]) } }
                .sheet(isPresented: $showDiagnostics) { DiagnosticsView() }
                .sheet(item: $sharing) { file in ActivitySheet(url: file.url) }
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
