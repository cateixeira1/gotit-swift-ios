import SwiftUI
import PhotosUI
import CryptoKit
import ImageIO
import PencilKit
import PDFKit
import AVFoundation
import UniformTypeIdentifiers
import GotItDomain
import GotItPersistence
import GotItCanvas
import GotItCanvasUI

@main
struct GotItAppApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup { AppScreen(model: model).task { await model.start() } }
            .onChange(of: scenePhase) { _, phase in
                model.semantic.setActive(phase == .active)
                model.assistant.setActive(phase == .active)
            }
    }
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
    /// Search by meaning (optional, model downloaded on request).
    let semantic = SemanticSearch()
    /// Gemma 4 E2B on the device (optional, model downloaded on request).
    let assistant = Assistant()

    func start() async {
        guard store == nil else { return }
        registerFonts()
        images.totalCostLimit = 64 * 1024 * 1024; images.countLimit = 48
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
            semantic.attach(repository)
            try await collectUnusedAssets()
            try await refresh()
            await openOnLaunch()
        } catch { self.error = String(describing: error) }
    }

    /// What the app shows when it opens (Ajustes › Ao abrir o app).
    enum LaunchTarget: String, CaseIterable, Identifiable {
        case list, newNote, newSimpleNote, lastNote
        var id: String { rawValue }
        var title: String {
            switch self {
            case .list: "Lista de notas"
            case .newNote: "Nova nota"
            case .newSimpleNote: "Nova nota simples"
            case .lastNote: "Última nota aberta"
            }
        }
    }
    static let launchKey = "launchTarget", lastDocumentKey = "lastDocument"
    var launchTarget: LaunchTarget {
        get { _ = launchTargetVersion; return UserDefaults.standard.string(forKey: Self.launchKey).flatMap(LaunchTarget.init) ?? .lastNote }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Self.launchKey); launchTargetVersion += 1 }
    }
    private var launchTargetVersion = 0
    /// Changes when the list should be brought to the front (the app opened on it).
    var showListRequest = 0

    /// The default font changed: the open note is shown again with it.
    func defaultFontChanged() async {
        guard let id = document?.id, !isSaving else { return }
        let page = selectedPageID
        document = nil
        await open(id)
        if let page, document?.pages.contains(where: { $0.id == page }) == true { selectedPageID = page }
    }

    private func openOnLaunch() async {
        #if DEBUG
        // UI tests expect the most recent note open.
        let target: LaunchTarget = ProcessInfo.processInfo.arguments.contains("--ui-testing") ? .lastNote : launchTarget
        #else
        let target = launchTarget
        #endif
        switch target {
        case .list:
            showListRequest += 1
        case .newNote:
            await createNote()
        case .newSimpleNote:
            await createSimpleNote()
        case .lastNote:
            if activeSummaries.isEmpty { await createNote(); return }
            let last = UserDefaults.standard.string(forKey: Self.lastDocumentKey).flatMap(UUID.init(uuidString:))
            let id = activeSummaries.first { $0.id == last }?.id ?? activeSummaries[0].id
            await open(id)
        }
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
        folders = try await store.listFolders()
        if let current = currentFolder, !folders.contains(where: { $0.id == current }) { currentFolder = nil }
        if let document, !document.pages.contains(where: { $0.id == selectedPageID }) { selectedPageID = document.pages.first?.id }
        let updatePreviews = Date().timeIntervalSince(lastPreviewTime) > 2
        if updatePreviews { lastPreviewTime = Date() }
        for summary in summaries where summary.kind == .note {
            guard previewRevisions[summary.id] != summary.revision, updatePreviews || noteMetadata[summary.id] == nil else { continue }
            // A thumbnail kept for this revision is used as it is; otherwise the note is drawn
            // (from memory when it is the one open) and its thumbnail kept for next time.
            let image: UIImage
            if let kept = PreviewCache.load(summary.id, revision: summary.revision) { image = kept }
            else {
                let note: CanvasDocument
                if let open = document, open.id == summary.id, open.revision == summary.revision { note = open } else { note = try await store.load(summary.id) }
                image = preview(note)
                PreviewCache.store(image, id: summary.id, revision: summary.revision)
            }
            noteMetadata[summary.id] = .init(title: summary.title, createdAt: summary.createdAt, preview: image)
            previewRevisions[summary.id] = summary.revision
        }
        semantic.changed()
    }

    /// Opens a note or Teia. `returningTo` is the Teia it was opened from; opening from the list
    /// (no origin) starts over.
    func open(_ id: UUID, returningTo origin: UUID? = nil) async {
        guard !isSaving, let store else { return }
        if let summary = summaries.first(where: { $0.id == id }), summary.isTrashed {
            error = "“\(summary.title)” está na Lixeira. Restaure para abrir."; return
        }
        do {
            let loaded = try await store.load(id)
            if let origin, origin != id { returnStack.append(origin) } else if origin == nil { returnStack.removeAll() }
            document = loaded; selectedPageID = loaded.pages.first?.id
            UserDefaults.standard.set(id.uuidString, forKey: Self.lastDocumentKey)
        }
        catch DocumentError.missingDocument { self.error = "Esta nota foi apagada para sempre." }
        catch { self.error = String(describing: error) }
    }

    /// UI tests that drive toolbars turn this off (the keyboard would cover them).
    let autofocusOnOpen = !ProcessInfo.processInfo.arguments.contains("--no-autofocus")

    /// Where the caret goes when a note opens, so typing can start at once: the end of the note's
    /// main text (the story that starts on the first page), or, when the note has no text yet, a
    /// new text box at the top of the first page's text area.
    func caretOnOpen() -> TextFlowFocus? {
        guard let document, document.kind == .note, let firstPage = document.pages.first?.id, !writeFailed else { return nil }
        let membership = document.pageAssignments()
        let stories = document.blocks.filter { $0.parentID == nil && $0.textFlowID == $0.id && membership[$0.id] == firstPage }
        if let story = stories.min(by: { $0.layout.frame.y == $1.layout.frame.y ? $0.order < $1.order : $0.layout.frame.y < $1.layout.frame.y }),
           let last = document.textFlowFragments(story: story.id).last, case .text(let rich) = last.content {
            return TextFlowFocus(blockID: last.id, pageID: membership[last.id] ?? firstPage,
                                 range: NSRange(location: (rich.plainText as NSString).length, length: 0), text: rich, frame: last.layout.frame)
        }
        let area = document.canvas.textArea
        var block = CanvasBlock(layout: .init(mode: .absolute, frame: .init(x: area.x, y: area.y, width: area.width, height: 44)), content: .text(RichText("")))
        block.textFlowID = block.id
        enqueue([.insertBlock(block)], pageID: firstPage, documentID: document.id)
        guard self.document?.blocks.contains(where: { $0.id == block.id }) == true else { return nil }
        return TextFlowFocus(blockID: block.id, pageID: firstPage, range: NSRange(location: 0, length: 0), frame: block.layout.frame)
    }

    // MARK: Busca

    /// One note in the search results: its best excerpt and how many places matched.
    struct SearchResult: Identifiable {
        let documentID: UUID
        let title: String
        let kind: DocumentKind
        let folder: String?
        let hit: SearchHit
        let matches: Int
        var id: UUID { documentID }
    }

    /// Notes where the words appear (best first, one row per note).
    func search(_ input: String) async -> [SearchResult] {
        guard let store else { return [] }
        do {
            let hits = try await store.search(input)
            var order: [UUID] = [], best: [UUID: SearchHit] = [:], counts: [UUID: Int] = [:]
            for hit in hits {
                if best[hit.documentID] == nil { best[hit.documentID] = hit; order.append(hit.documentID) }
                counts[hit.documentID, default: 0] += 1
            }
            return order.compactMap { id in
                guard let summary = summaries.first(where: { $0.id == id && !$0.isTrashed }), let hit = best[id] else { return nil }
                return SearchResult(documentID: id, title: summary.title, kind: summary.kind,
                                    folder: summary.folderID.map { folderName($0) }, hit: hit, matches: counts[id] ?? 1)
            }
        } catch { self.error = String(describing: error); return [] }
    }

    /// Notes about what was searched, found by meaning rather than by the words (best first, one
    /// row per note), leaving out `excluding` (the notes the words already found). Only passages
    /// close enough to the query and to the best one are kept.
    func searchByMeaning(_ input: String, excluding: Set<UUID>) async -> [SearchResult] {
        let hits = await semantic.search(input)
        guard let best = hits.first?.score else { return [] }
        var order: [UUID] = [], first: [UUID: SemanticHit] = [:], counts: [UUID: Int] = [:]
        for hit in hits where hit.score >= max(Self.meaningFloor, best - Self.meaningSpread) && !excluding.contains(hit.documentID) {
            if first[hit.documentID] == nil { first[hit.documentID] = hit; order.append(hit.documentID) }
            counts[hit.documentID, default: 0] += 1
        }
        return order.prefix(8).compactMap { id in
            guard let summary = summaries.first(where: { $0.id == id && !$0.isTrashed }), let hit = first[id] else { return nil }
            let excerpt = hit.text.count > 180 ? String(hit.text.prefix(180)) + "…" : hit.text
            return SearchResult(documentID: id, title: summary.title, kind: summary.kind, folder: summary.folderID.map { folderName($0) },
                                hit: SearchHit(documentID: id, blockID: hit.blockID, kind: .text, snippet: excerpt), matches: counts[id] ?? 1)
        }
    }

    /// From EmbeddingGemma 2 on Portuguese notes (the real-model test in CI): a note on the
    /// query's subject scored 0.69–0.76, notes on other subjects 0.54–0.66. To be revisited with
    /// more real notes.
    static let meaningFloor: Float = 0.66, meaningSpread: Float = 0.06

    /// Passages of the notes to answer `question` from, best first. Found by meaning (a wider net
    /// than the list's "Por significado": the model is told to say when they do not answer); with
    /// `scope`, only in those notes, and when the search by meaning is off, their first passages.
    func assistantSources(for question: String, in scope: Set<UUID> = []) async -> [AssistantPrompts.Source] {
        let chosen = scope.filter { id in activeSummaries.contains { $0.id == id } }
        let title: (UUID) -> String = { id in self.summaries.first { $0.id == id }?.title ?? "" }
        if semantic.canSearch {
            let hits = await semantic.search(question, in: chosen.isEmpty ? nil : chosen)
            if let best = hits.first?.score {
                // Within chosen notes the best passages go even when the scores are low.
                let floor = chosen.isEmpty ? max(Self.meaningFloor - 0.08, best - 0.1) : best - 0.15
                let candidates = hits.filter { $0.score >= floor && summaries.contains { s in s.id == $0.documentID && !s.isTrashed } }
                    .map { AssistantPrompts.Source(documentID: $0.documentID, blockID: $0.blockID, title: title($0.documentID), text: $0.text) }
                if !candidates.isEmpty { return AssistantPrompts.pick(candidates) }
            }
        }
        guard !chosen.isEmpty, let store else { return [] }
        // Not read for the search by meaning (off, or not yet): the beginning of each chosen note.
        var candidates: [AssistantPrompts.Source] = []
        let share = AssistantPrompts.sourcesLimit / max(chosen.count, 1)
        for id in activeSummaries.map(\.id) where chosen.contains(id) {
            guard let note = try? await store.load(id) else { continue }
            var used = 0
            for chunk in SemanticChunks.chunks(note) where used < share {
                candidates.append(.init(documentID: id, blockID: chunk.blockID, title: note.title, text: chunk.text))
                used += chunk.text.count
            }
        }
        return AssistantPrompts.pick(candidates)
    }

    /// Opens `documentID` with the caret at `blockID` (a source of the assistant's answer).
    func openSource(_ source: AssistantPrompts.Source) async {
        let hit = SearchHit(documentID: source.documentID, blockID: source.blockID, kind: .text, snippet: "")
        let kind = summaries.first { $0.id == source.documentID }?.kind ?? .note
        await open(SearchResult(documentID: source.documentID, title: source.title, kind: kind, folder: nil, hit: hit, matches: 1), query: "")
    }

    /// Puts the assistant's text in the open note, below what is on the page being shown. False
    /// (with a message) when the page has no room left.
    @discardableResult
    func insertAssistantText(_ text: String) async -> Bool {
        let body = AssistantPrompts.plainText(text)
        guard !body.isEmpty, let current = document, let page = activePageID,
              let projection = try? current.pageDocument(page) else { return false }
        let area = current.canvas.textArea
        let bottom = projection.blocks.filter { $0.parentID == nil && !Stickers.isFolded($0) }.compactMap { block -> Double? in
            switch block.content {
            case .drawing: return nil
            case .text(let rich) where rich.plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty: return nil
            default: return block.layout.frame.y + block.layout.frame.height
            }
        }.max()
        let y = max(area.y, (bottom ?? area.y) + 12)
        guard y + 44 <= area.y + area.height else {
            self.error = "Não há espaço nesta página para o texto do assistente. Vá para uma página com espaço (ou crie uma) e toque em Inserir de novo, ou copie o texto."
            return false
        }
        var box = CanvasBlock(layout: .init(mode: .absolute, frame: .init(x: area.x, y: y, width: area.width, height: 44)), content: .text(RichText("")))
        box.textFlowID = box.id
        enqueue([.insertBlock(box)], pageID: page, documentID: current.id)
        while isSaving { try? await Task.sleep(for: .milliseconds(30)) }
        guard var inserted = self.document?.blocks.first(where: { $0.id == box.id }) else { return false }
        inserted.content = .text(RichText(body))
        _ = editText(inserted, group: nil, selection: NSRange(location: 0, length: 0))
        return true
    }

    /// Where to take the caret once a note opened from the search results is on screen.
    private var reveal: (blockID: UUID, query: String)?
    /// Changes when a found place should be shown (the editor then calls `takeRevealFocus`).
    var revealRequest = 0

    /// Opens a note at what was found: its page, and in a text the found word selected.
    func open(_ result: SearchResult, query: String) async {
        await open(result.documentID)
        guard let document, document.id == result.documentID, let block = result.hit.blockID else { return }
        if let page = document.pageID(for: block) { selectedPageID = page }
        reveal = (block, query)
        revealRequest += 1
    }

    var revealPending: Bool { reveal != nil }

    func takeRevealFocus() -> TextFlowFocus? {
        guard let target = reveal else { return nil }
        reveal = nil
        guard let document, let block = document.blocks.first(where: { $0.id == target.blockID }),
              case .text(let rich) = block.content, let page = document.pageID(for: block.id) else { return nil }
        let range = SearchText.firstMatch(of: target.query, in: rich.plainText) ?? NSRange(location: 0, length: 0)
        return TextFlowFocus(blockID: block.id, pageID: page, range: range, text: rich, frame: block.layout.frame)
    }

    // MARK: Ligações entre notas

    /// Notes and Teias (not in the Lixeira) that cite `id`, by title.
    func backlinks(to id: UUID) async -> [DocumentSummary] {
        guard let store else { return [] }
        do {
            let sources = Set(try await store.backlinks(to: id))
            return activeSummaries.filter { sources.contains($0.id) }
                .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        } catch { self.error = String(describing: error); return [] }
    }

    // MARK: Pastas

    var folders: [Folder] = []
    /// The folder the list shows (nil: the top level); new notes and Teias are filed there.
    var currentFolder: UUID? = UserDefaults.standard.string(forKey: "currentFolder").flatMap(UUID.init(uuidString:)) {
        didSet { UserDefaults.standard.set(currentFolder?.uuidString, forKey: "currentFolder") }
    }

    func folder(_ id: UUID?) -> Folder? { id.flatMap { id in folders.first { $0.id == id } } }
    func folderName(_ id: UUID?) -> String { folder(id)?.name ?? "Início" }
    func subfolders(of parent: UUID?) -> [Folder] { folders.filter { $0.parentID == parent } }
    /// Notes and Teias filed in the folder shown (not in the Lixeira).
    var visibleSummaries: [DocumentSummary] { activeSummaries.filter { $0.folderID == currentFolder } }
    /// Notes and Teias directly inside a folder.
    func count(in folder: UUID) -> Int { activeSummaries.filter { $0.folderID == folder }.count + subfolders(of: folder).count }

    struct FolderItem: Identifiable { let folder: Folder; let depth: Int; var id: UUID { folder.id } }
    /// Every folder with its depth, parents before their subfolders (for "Mover para").
    var folderTree: [FolderItem] {
        var result: [FolderItem] = [], seen: Set<UUID> = []
        func add(_ parent: UUID?, _ depth: Int) {
            for folder in subfolders(of: parent) where seen.insert(folder.id).inserted {
                result.append(FolderItem(folder: folder, depth: depth)); add(folder.id, depth + 1)
            }
        }
        add(nil, 0)
        return result
    }

    /// `id` and every folder inside it (a folder cannot be moved into any of them).
    func descendants(of id: UUID) -> Set<UUID> {
        var found: Set<UUID> = [id], pending = [id]
        while let next = pending.popLast() {
            for child in subfolders(of: next) where found.insert(child.id).inserted { pending.append(child.id) }
        }
        return found
    }

    func createFolder(named name: String) async {
        guard let store else { return }
        do { _ = try await store.createFolder(named: name, in: currentFolder); try await refresh() }
        catch DocumentError.invalid(let reason) { self.error = reason }
        catch { self.error = String(describing: error) }
    }

    func renameFolder(_ id: UUID, to name: String) async {
        guard let store else { return }
        do { try await store.renameFolder(id, to: name); try await refresh() }
        catch DocumentError.invalid(let reason) { self.error = reason }
        catch { self.error = String(describing: error) }
    }

    func moveFolder(_ id: UUID, to parent: UUID?) async {
        guard let store else { return }
        do { try await store.moveFolder(id, to: parent); try await refresh() }
        catch DocumentError.invalid(let reason) { self.error = reason }
        catch { self.error = String(describing: error) }
    }

    /// The folder goes; what was inside it moves up to its parent.
    func deleteFolder(_ id: UUID) async {
        guard let store else { return }
        let parent = folder(id)?.parentID
        do {
            try await store.deleteFolder(id)
            if let current = currentFolder, descendants(of: id).contains(current) { currentFolder = current == id ? parent : current }
            try await refresh()
        } catch { self.error = String(describing: error) }
    }

    func moveDocument(_ id: UUID, to folder: UUID?) async {
        guard let store else { return }
        do { try await store.moveDocument(id, to: folder); try await refresh() }
        catch DocumentError.invalid(let reason) { self.error = reason }
        catch { self.error = String(describing: error) }
    }

    /// A note or Teia just made goes into the folder being shown.
    private func file(_ document: CanvasDocument) async throws {
        guard let store, let folder = currentFolder else { return }
        try await store.moveDocument(document.id, to: folder)
    }

    // MARK: Lixeira

    private var lastTrashed = Date.distantPast
    var activeSummaries: [DocumentSummary] { summaries.filter { !$0.isTrashed } }
    /// Most recently deleted first.
    var trashedSummaries: [DocumentSummary] {
        summaries.filter(\.isTrashed).sorted { ($0.trashedAt ?? .distantPast) > ($1.trashedAt ?? .distantPast) }
    }

    /// Saves still in flight finish first, so nothing typed just before is lost or misplaced.
    private func waitForSaves() async {
        for _ in 0..<200 where isSaving { try? await Task.sleep(for: .milliseconds(25)) }
    }

    /// Swipe to delete: the note or Teia goes to the Lixeira, whole, and can come back.
    func moveToTrash(_ id: UUID) async {
        await waitForSaves()
        guard !isSaving, let store else { return }
        do {
            // Times are kept in milliseconds: two deletions in the same millisecond keep their order.
            let when = max(Date(), lastTrashed.addingTimeInterval(0.002))
            lastTrashed = when
            try await store.moveToTrash(id, at: when)
            if document?.id == id { document = nil; selectedPageID = nil }
            returnStack.removeAll { $0 == id }
            try await refresh()
        } catch { self.error = String(describing: error) }
    }

    func restoreFromTrash(_ id: UUID) async {
        guard let store else { return }
        do { try await store.restoreFromTrash(id); try await refresh() }
        catch { self.error = String(describing: error) }
    }

    func deleteForever(_ id: UUID) async {
        guard let store, let summary = summaries.first(where: { $0.id == id }) else { return }
        do {
            try await store.deleteDocument(id, expectedRevision: summary.revision)
            forget(id)
            try await refresh()
        } catch { self.error = String(describing: error) }
    }

    func emptyTrash() async {
        guard let store else { return }
        do {
            let gone = trashedSummaries.map(\.id)
            try await store.emptyTrash()
            for id in gone { forget(id) }
            try await refresh()
        } catch { self.error = String(describing: error) }
    }

    private func forget(_ id: UUID) {
        noteMetadata[id] = nil; previewRevisions[id] = nil
        PreviewCache.remove(id)
        if document?.id == id { document = nil; selectedPageID = nil }
        returnStack.removeAll { $0 == id }
    }

    /// Back to the Teia this note was opened from.
    func goBack() async {
        guard !isSaving, let store, let origin = returnStack.last else { return }
        do {
            let loaded = try await store.load(origin)
            returnStack.removeLast()
            document = loaded; selectedPageID = loaded.pages.first?.id
            UserDefaults.standard.set(id.uuidString, forKey: Self.lastDocumentKey)
        } catch { returnStack.removeLast(); self.error = String(describing: error) }
    }
    var returnTitle: String? {
        returnStack.last.map { id in summaries.first { $0.id == id }?.title ?? "Teia" }
    }

    func createNote() async {
        guard !isSaving, let store else { return }
        returnStack.removeAll()
        do {
            // A4 with Word's margins: the text area of a new Word document.
            var note = CanvasDocument(title: "Nota \(summaries.filter { $0.kind == .note }.count + 1)", defaultStyle: .init(fontSize: 18))
            note.canvas.margins = .word
            document = try await store.create(note)
            if let created = document { try await file(created) }
            try await refresh()
        } catch { self.error = String(describing: error) }
    }

    /// A simple note: yellow ruled paper and text only, like a legal pad.
    func createSimpleNote() async {
        guard !isSaving, let store else { return }
        returnStack.removeAll()
        do {
            let note = CanvasDocument(title: "Nota \(summaries.filter { $0.kind == .note }.count + 1)", defaultStyle: .init(fontSize: 18),
                                      canvas: .simpleNote())
            document = try await store.create(note)
            if let created = document { try await file(created) }
            try await refresh()
        } catch { self.error = String(describing: error) }
    }

    func createWeb(including id: UUID? = nil) async {
        guard !isSaving, let store else { return }
        returnStack.removeAll()
        do {
            var web = CanvasDocument(title: "Teia \(summaries.filter { $0.kind == .web }.count + 1)", kind: .web)
            // A Teia is a landscape page (A4 lying down): cards spread sideways.
            web.canvas.size = CanvasSize(width: CanvasSize.a4.height, height: CanvasSize.a4.width)
            if let id, let summary = summaries.first(where: { $0.id == id && $0.kind == .note }) {
                web = try CommandEngine.applying(TeiaEngine.addNotes([.init(id: summary.id, title: summary.title, createdAt: summary.createdAt)], to: web), to: web)
            }
            document = try await store.create(web)
            if let created = document { try await file(created) }
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
            DerivedImages.remove(url.lastPathComponent)
        }
    }

    func history(undo: Bool) async {
        guard !isSaving, !writeFailed, let document, let store else { return }
        do {
            self.document = try await (undo ? store.undo(documentID: document.id, expectedRevision: document.revision) : store.redo(documentID: document.id, expectedRevision: document.revision))
            try await refresh()
        } catch { self.error = String(describing: error) }
    }

    /// The picture a page shows for an asset. Large photos, a video's first frame and a PDF's
    /// first page come from smaller copies kept in Caches (`DerivedImages`), made the first time.
    func image(_ hash: String) -> UIImage? {
        if let cached = images.object(forKey: hash as NSString) { return cached }
        guard let url = assetURL(hash), FileManager.default.fileExists(atPath: url.path) else { return nil }
        let type = document?.assets.first(where: { $0.hash == hash })?.mediaType
        let made: UIImage?
        if type?.hasPrefix("audio/") == true { return nil }
        else if type?.hasPrefix("video/") == true { made = DerivedImages.image(hash, role: .poster) { poster(hash)?.cgImage } }
        else if type == "application/pdf" || (type == nil && Self.looksLikePDF(url)) {
            made = DerivedImages.image(hash, role: .pdfPage) {
                guard let pdf = PDFDocument(url: url), let page = pdf.page(at: 0) else { return nil }
                return page.thumbnail(of: CGSize(width: 600, height: 850), for: .mediaBox).cgImage
            }
        } else { made = DerivedImages.picture(hash, original: url) }
        guard let made else { return nil }
        images.setObject(made, forKey: hash as NSString, cost: Int(made.size.width * made.size.height * made.scale * made.scale * 4))
        return made
    }

    /// A file that starts like a PDF (assets are stored without an extension).
    private static func looksLikePDF(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: 5)) == Data("%PDF-".utf8)
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
                // The text did not need to move (the object went somewhere it does not wrap): nothing to apply.
                guard !result.commands.isEmpty else { continue }
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

    /// An edit of a selection that runs across pages: the story is edited as one text and laid
    /// out again, in one undo step.
    func editStory(_ story: UUID, range: NSRange, edit: StoryEdit) -> TextFlowFocus? {
        guard let document, !writeFailed else { return nil }
        do {
            let result = try StoryEditing.apply(edit, to: range, story: story, in: document)
            enqueue(result.commands, historyGroup: nil)
            // Typing or deleting moves the caret (and the page list) to where the edit ended.
            if case .format = edit {} else if !writeFailed { selectedPageID = result.focus.pageID }
            return result.focus
        } catch { self.error = String(describing: error); return nil }
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

    /// Audio and video: hashed in 1 MB pieces and copied as a file, away from the main thread, so
    /// a long recording or a large video is never read into memory whole.
    private func storeAsset(file url: URL, mediaType: String) async throws -> Asset {
        guard let directory else { throw DocumentError.invalid("Storage unavailable") }
        let folder = directory.appendingPathComponent("assets")
        return try await Task.detached(priority: .userInitiated) { try Self.storeFile(url, mediaType: mediaType, in: folder) }.value
    }

    nonisolated static func storeFile(_ url: URL, mediaType: String, in folder: URL) throws -> Asset {
        let hash = try sha256(of: url)
        let destination = folder.appendingPathComponent(hash)
        if !FileManager.default.fileExists(atPath: destination.path) {
            // Copied beside the target and moved into place: a half-copied file never has the hash's name.
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.copyItem(at: url, to: temporary)
            // A copy keeps the source's date; a fresh one keeps it out of the cleanup of old orphans.
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: temporary.path)
            do { try FileManager.default.moveItem(at: temporary, to: destination) }
            catch {
                try? FileManager.default.removeItem(at: temporary)
                if !FileManager.default.fileExists(atPath: destination.path) { throw error }
            }
        }
        let bytes = try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        return Asset(hash: hash, mediaType: mediaType, byteCount: Int64(bytes))
    }

    nonisolated static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func storeAsset(_ data: Data, mediaType: String) throws -> Asset {
        guard let directory else { throw DocumentError.invalid("Storage unavailable") }
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let destination = directory.appendingPathComponent("assets").appendingPathComponent(hash)
        if !FileManager.default.fileExists(atPath: destination.path) { try data.write(to: destination, options: .atomic) }
        return Asset(hash: hash, mediaType: mediaType, byteCount: Int64(data.count))
    }

    /// Saves a page's drawing. Strokes only added since the last save become one more small part
    /// (`AssetReference.parts`) instead of a new copy of the whole page; any other change writes the
    /// whole drawing again and lets the old base and parts go.
    func saveDrawing(_ save: DrawingSave, extra: [DocumentCommand], pageID: UUID, documentID: UUID) {
        guard let document, document.id == documentID, !writeFailed else { return }
        do {
            let existing = document.blocks.first { block in
                if case .drawing = block.content { return document.pageID(for: block.id) == pageID }; return false
            }
            var commands = extra
            var reference: AssetReference?
            switch save {
            case .unchanged:
                guard !commands.isEmpty else { return }
            case .appended(let data):
                let asset = try storeAsset(data, mediaType: "application/x-pencilkit")
                if !document.assets.contains(where: { $0.hash == asset.hash }) { commands.append(.registerAsset(asset)) }
                if case .drawing(let current)? = existing?.content {
                    reference = AssetReference(hash: current.hash, parts: (current.parts ?? []) + [asset.hash])
                } else {
                    reference = AssetReference(hash: asset.hash)          // the page had no drawing yet
                }
            case .full(let data):
                if try PKDrawing(data: data).strokes.isEmpty {
                    if let existing { commands.append(.removeSubtree(existing.id)) }
                } else {
                    let asset = try storeAsset(data, mediaType: "application/x-pencilkit")
                    if !document.assets.contains(where: { $0.hash == asset.hash }) { commands.append(.registerAsset(asset)) }
                    reference = AssetReference(hash: asset.hash)
                }
            }
            if let reference {
                var block = existing ?? CanvasBlock(layout: .init(mode: .absolute, frame: .init(x: 0, y: 0, width: document.canvas.size.width, height: document.canvas.size.height), zIndex: 1000), content: .drawing(reference), presentation: .init(wrap: .none))
                block.content = .drawing(reference)
                commands.append(existing == nil ? .insertBlock(block) : .replaceBlock(block))
            }
            // Assets the page no longer uses (an earlier whole drawing and its parts).
            if let existing, case .full = save {
                let keep = Set(reference?.allHashes ?? [])
                for hash in existing.content.assetHashes where !keep.contains(hash)
                    && !document.blocks.contains(where: { $0.id != existing.id && $0.content.assetHashes.contains(hash) }) {
                    commands.append(.unregisterAsset(hash))
                }
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
            let spot = freeSpot(width: width, height: width * aspect, pageID: pageID, in: current)
            let block = CanvasBlock(layout: .init(mode: .absolute, frame: .init(x: spot.x, y: spot.y, width: width, height: width * aspect)), content: sticker ? .sticker(.init(hash: asset.hash)) : .image(.init(hash: asset.hash)))
            enqueue((current.assets.contains(where: { $0.hash == asset.hash }) ? [] : [.registerAsset(asset)]) + [.insertBlock(block)], pageID: pageID, documentID: documentID)
        } catch { self.error = String(describing: error) }
    }

    // MARK: Video

    /// A video from the gallery or Files goes on the page with its first frame and the shape of
    /// the video, at the first free spot; a tap plays it.
    /// `reduce`: the user chose to insert videos as a smaller copy (Ferramentas › Vídeos ao inserir).
    func insertVideo(from url: URL, pageID: UUID, documentID: UUID, reduce: VideoReduction.Quality? = nil) async {
        guard let current = document, current.id == documentID else { return }
        do {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let type = UTType(filenameExtension: url.pathExtension)
            guard type?.conforms(to: .movie) ?? true else { throw DocumentError.invalid("O arquivo não é um vídeo.") }
            var file = url, mediaType = type?.preferredMIMEType ?? "video/quicktime"
            if let reduce {
                reducingVideos += 1
                defer { reducingVideos -= 1 }
                let bytes = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                // A video that would not get smaller goes in as it is.
                if let smaller = try await VideoReduction.reduce(AVURLAsset(url: url), originalBytes: bytes, quality: reduce) {
                    file = smaller; mediaType = "video/mp4"
                }
            }
            defer { if file != url { try? FileManager.default.removeItem(at: file) } }
            let asset = try await storeAsset(file: file, mediaType: mediaType)
            var aspect = 9.0 / 16.0
            if let track = try await AVURLAsset(url: url).loadTracks(withMediaType: .video).first {
                let (size, transform) = try await track.load(.naturalSize, .preferredTransform)
                let shown = size.applying(transform)
                if abs(shown.width) > 0 { aspect = Double(abs(shown.height) / abs(shown.width)) }
            }
            guard let latest = document, latest.id == documentID else { return }
            let width = min(320, latest.canvas.size.width * 0.6), height = width * aspect
            let spot = freeSpot(width: width, height: height, pageID: pageID, in: latest)
            let block = CanvasBlock(layout: .init(mode: .absolute, frame: .init(x: spot.x, y: spot.y, width: width, height: height)),
                                    content: .video(AssetReference(hash: asset.hash)))
            enqueue((latest.assets.contains { $0.hash == asset.hash } ? [] : [.registerAsset(asset)]) + [.insertBlock(block)], pageID: pageID, documentID: documentID)
        } catch DocumentError.invalid(let reason) { self.error = reason }
        catch { self.error = "Não foi possível inserir o vídeo: \(error.localizedDescription)" }
    }

    /// Videos being reduced now (shown as a progress notice).
    var reducingVideos = 0

    /// Replaces a video on the page by a smaller copy, if it saves space; one undo step brings the
    /// original back. The original file stays while the history needs it.
    func reduceVideo(_ blockID: UUID, quality: VideoReduction.Quality) async {
        guard let document, !writeFailed, let block = document.blocks.first(where: { $0.id == blockID }),
              case .video(let reference) = block.content, let media = mediaAsset(reference.hash) else { return }
        let original = document.assets.first { $0.hash == reference.hash }?.byteCount ?? 0
        reducingVideos += 1
        defer { reducingVideos -= 1 }
        do {
            guard let smaller = try await VideoReduction.reduce(media, originalBytes: original, quality: quality) else {
                self.error = "Este vídeo já está compacto: reduzi-lo não economizaria espaço."; return
            }
            defer { try? FileManager.default.removeItem(at: smaller) }
            let asset = try await storeAsset(file: smaller, mediaType: "video/mp4")
            while isSaving { try await Task.sleep(for: .milliseconds(30)) }
            guard let latest = self.document, latest.id == document.id, var current = latest.blocks.first(where: { $0.id == blockID }),
                  case .video(let now) = current.content, now.hash == reference.hash else { return }
            current.content = .video(AssetReference(hash: asset.hash, caption: now.caption))
            var commands: [DocumentCommand] = latest.assets.contains { $0.hash == asset.hash } ? [] : [.registerAsset(asset)]
            commands.append(.replaceBlock(current))
            if !latest.blocks.contains(where: { $0.id != blockID && $0.content.assetHash == reference.hash }) { commands.append(.unregisterAsset(reference.hash)) }
            enqueue(commands)
            images.removeObject(forKey: asset.hash as NSString)
            self.error = "Vídeo reduzido de \(VideoReduction.megabytes(original)) para \(VideoReduction.megabytes(asset.byteCount)). Desfazer traz o original de volta."
        } catch { self.error = "Não foi possível reduzir o vídeo: \(error.localizedDescription)" }
    }

    /// Size of a stored asset, for the reduce dialog.
    func assetBytes(_ hash: String) -> Int64 { document?.assets.first { $0.hash == hash }?.byteCount ?? 0 }

    /// The stored file of an audio or video, read with its media type (assets are saved without extension).
    func mediaAsset(_ hash: String) -> AVURLAsset? {
        guard let url = assetURL(hash), FileManager.default.fileExists(atPath: url.path) else { return nil }
        let type = document?.assets.first { $0.hash == hash }?.mediaType ?? "video/quicktime"
        return AVURLAsset(url: url, options: [AVURLAssetOverrideMIMETypeKey: type])
    }

    /// First frame of a video, for the block on the page.
    private func poster(_ hash: String) -> UIImage? {
        guard let media = mediaAsset(hash) else { return nil }
        let generator = AVAssetImageGenerator(asset: media)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1280, height: 1280)
        guard let frame = try? generator.copyCGImage(at: CMTime(seconds: 0.2, preferredTimescale: 600), actualTime: nil) else { return nil }
        return UIImage(cgImage: frame)
    }

    // MARK: Audio

    /// Audio being transcribed (block ids), to show progress and avoid starting twice.
    var transcribing: Set<UUID> = []

    /// A recording or an audio file goes on the page as a player (first free spot); with
    /// `transcribe`, its text is written below it once the device has transcribed it.
    func insertAudio(from url: URL, transcribe: TranscriptPlacement?, pageID: UUID, documentID: UUID) async {
        guard document?.id == documentID else { return }
        do {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let type = UTType(filenameExtension: url.pathExtension)
            guard type?.conforms(to: .audio) ?? true else { throw DocumentError.invalid("O arquivo não é um áudio.") }
            let asset = try await storeAsset(file: url, mediaType: type?.preferredMIMEType ?? "audio/mp4")
            // The note may have changed while the file was copied.
            guard let latest = self.document, latest.id == documentID, latest.pages.contains(where: { $0.id == pageID }) else { return }
            let size = (width: 320.0, height: Stickers.audioHeight)
            let spot = freeSpot(width: size.width, height: size.height, pageID: pageID, in: latest)
            let block = CanvasBlock(layout: .init(mode: .absolute, frame: .init(x: spot.x, y: spot.y, width: size.width, height: size.height)),
                                    content: .audio(AssetReference(hash: asset.hash)))
            enqueue((latest.assets.contains { $0.hash == asset.hash } ? [] : [.registerAsset(asset)]) + [.insertBlock(block)], pageID: pageID, documentID: documentID)
            if let transcribe { await self.transcribe(block.id, placement: transcribe) }
        } catch DocumentError.invalid(let reason) { self.error = reason }
        catch { self.error = error.localizedDescription }
    }

    /// Where a transcription goes: its own card beside the audio, or text in the note below it.
    enum TranscriptPlacement: String, CaseIterable { case card, text }

    /// Transcribes an audio on the device and puts the text either in a card with its own icon
    /// beside the audio (right, else left, below, above) or in the note's text below it.
    func transcribe(_ blockID: UUID, placement: TranscriptPlacement = .card) async {
        guard let document, !transcribing.contains(blockID),
              let block = document.blocks.first(where: { $0.id == blockID }), case .audio(let reference) = block.content,
              let stored = assetURL(reference.hash) else { return }
        transcribing.insert(blockID)
        defer { transcribing.remove(blockID) }
        let mediaType = document.assets.first { $0.hash == reference.hash }?.mediaType ?? "audio/mp4"
        let ext = UTType(mimeType: mediaType)?.preferredFilenameExtension ?? "m4a"
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
        do {
            try FileManager.default.copyItem(at: stored, to: copy)
            defer { try? FileManager.default.removeItem(at: copy) }
            let result = try await AudioTranscription.transcribe(copy)
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { self.error = "Nenhuma fala foi reconhecida neste áudio (idioma: \(result.language))."; return }
            // Speech runs at ~2 words a second; far fewer means something went wrong: say so, with the details.
            let words = text.split(whereSeparator: \.isWhitespace).count
            if result.seconds > 20, Double(words) < result.seconds / 6 {
                self.error = "A transcrição veio curta para o áudio: \(words) palavras em \(Int(result.seconds)) s (\(result.engine), \(result.language)). Confira o texto; se estiver errado, me envie esses números."
            }
            while isSaving { try await Task.sleep(for: .milliseconds(30)) }
            guard let current = self.document, current.id == document.id,
                  let audio = current.blocks.first(where: { $0.id == blockID }),
                  let page = current.pageID(for: blockID) else { return }
            if placement == .card, placeTranscriptCard(text, beside: audio, page: page, in: current) { return }
            if placement == .card { self.error = "A transcrição é longa demais para um bloco: ela foi colocada no texto da nota." }
            let area = current.canvas.textArea, frame = audio.layout.frame
            let x = min(max(frame.x, area.x), area.x + area.width - 80)
            var box = CanvasBlock(layout: .init(mode: .absolute, frame: .init(x: x, y: frame.y + frame.height + 8, width: area.x + area.width - x, height: 44)),
                                  content: .text(RichText("")))
            box.textFlowID = box.id
            enqueue([.insertBlock(box)], pageID: page, documentID: current.id)
            while isSaving { try await Task.sleep(for: .milliseconds(30)) }
            guard var inserted = self.document?.blocks.first(where: { $0.id == box.id }) else { return }
            inserted.content = .text(RichText(text))
            _ = editText(inserted, group: nil, selection: NSRange(location: 0, length: 0))
        } catch let failure as AudioTranscription.Failure { self.error = failure.errorDescription }
        catch { self.error = "Não foi possível transcrever: \(error.localizedDescription)" }
    }

    /// A card sized to its text (wider for long texts), beside the audio. False when even a wide
    /// card would not fit on the page.
    private func placeTranscriptCard(_ text: String, beside audio: CanvasBlock, page: UUID, in document: CanvasDocument) -> Bool {
        let size = document.canvas.size
        let font = UIFont.systemFont(ofSize: Stickers.transcriptFontSize)
        func height(_ width: Double) -> Double {
            let inner = width - 2 * Stickers.transcriptInset
            let box = (text as NSString).boundingRect(with: CGSize(width: inner - 10, height: .greatestFiniteMagnitude),
                                                      options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font], context: nil)
            return ceil(box.height) + 24 + Stickers.transcriptHeader + Stickers.transcriptInset
        }
        guard let width = [280.0, 360.0, 460.0, size.width - 32].first(where: { height($0) <= size.height - 32 }) else { return false }
        let cardHeight = height(width)
        guard let projection = try? document.pageDocument(page) else { return false }
        let spot = Placement.beside(audio.layout.frame, width: width, height: cardHeight, on: projection, except: [audio.id])
        enqueue(Stickers.transcript(at: spot, width: width, height: cardHeight, text: text, order: nextRootOrder(in: document)), pageID: page, documentID: document.id)
        return true
    }

    // MARK: Fonts for handwriting

    /// Bundled handwriting fonts (SIL Open Font License) and the ones the user imported.
    private(set) var handwritingFonts: [String] = HandwritingFonts.bundled.map(\.postScript)
    private var fontsFolder: URL? {
        try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Fonts", isDirectory: true)
    }

    /// Makes the bundled and imported fonts usable (called once at start).
    func registerFonts() {
        let bundled = ["ttf", "otf"].flatMap { Bundle.main.urls(forResourcesWithExtension: $0, subdirectory: nil) ?? [] }
        HandwritingFonts.register(bundled)
        defer { AppFonts.reload() }
        guard let folder = fontsFolder, let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return }
        let imported = HandwritingFonts.register(files)
        handwritingFonts = HandwritingFonts.bundled.map(\.postScript) + imported.filter { !HandwritingFonts.bundled.map(\.postScript).contains($0) }
    }

    /// Copies font files into the app (they stay on this device) and returns their names.
    func importFonts(_ urls: [URL]) -> [String] {
        guard let folder = fontsFolder else { return [] }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var names: [String] = []
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let copy = folder.appendingPathComponent(url.lastPathComponent)
            try? FileManager.default.removeItem(at: copy)
            guard (try? FileManager.default.copyItem(at: url, to: copy)) != nil else { continue }
            if let name = HandwritingFonts.register([copy]).first { names.append(name) }
            else { try? FileManager.default.removeItem(at: copy); self.error = "“\(url.lastPathComponent)” não é uma fonte que o iOS consiga usar." }
        }
        handwritingFonts += names.filter { !handwritingFonts.contains($0) }
        return names
    }

    /// Where a paper style goes.
    enum PaperScope: String, CaseIterable, Identifiable {
        case note, page, topHalf, bottomHalf
        var id: Self { self }
        var title: String {
            switch self { case .note: "Nota inteira"; case .page: "Só esta página"; case .topHalf: "Metade de cima"; case .bottomHalf: "Metade de baixo" }
        }
    }

    /// Paper for the whole note (every page), or for one page or half of it. Plain on a page
    /// removes that page's own paper.
    func setPaper(_ style: PaperStyle, scope: PaperScope, pageID: UUID) {
        guard let document, !writeFailed else { return }
        switch scope {
        case .note:
            var settings = document.canvas
            settings.paper = style.kind == .plain ? nil : style
            enqueue([.setCanvasSettings(settings)])
        case .page, .topHalf, .bottomHalf:
            let region: PaperFill.Region = scope == .page ? .full : scope == .topHalf ? .topHalf : .bottomHalf
            let fill: PaperFill? = style.kind == .plain && scope == .page && document.canvas.paper == nil ? nil : PaperFill(style: style, region: region)
            enqueue([.setPagePaper(pageID, fill)])
        }
    }

    /// New margins, header, footer or page numbers: stored, and every text of the note laid out
    /// again in the new text area (continuation pages start below the header, text stops above
    /// the footer). One undo step.
    func applyPageLayout(_ settings: CanvasSettings, assets: [Asset] = []) {
        guard let document, !writeFailed else { return }
        do {
            var commands: [DocumentCommand] = assets.filter { asset in !document.assets.contains { $0.hash == asset.hash } }
                .reduce(into: []) { list, asset in if !list.contains(.registerAsset(asset)) { list.append(.registerAsset(asset)) } }
            commands.append(.setCanvasSettings(settings))
            var working = try CommandEngine.applying(commands, to: document)
            let area = settings.textArea, oldArea = document.canvas.textArea
            for story in working.blocks where story.parentID == nil && story.textFlowID == story.id {
                var first = story
                // Text that sat in the old text area follows it (margins changed, a header grew).
                if abs(first.layout.frame.x - oldArea.x) < 0.5, abs(first.layout.frame.width - oldArea.width) < 0.5 {
                    first.layout.frame.x = area.x; first.layout.frame.width = area.width
                }
                if first.layout.frame.y < area.y { first.layout.frame.y = area.y }
                for fragment in working.textFlowFragments(story: story.id) where fragment.id != story.id
                    && abs(fragment.layout.frame.x - oldArea.x) < 0.5 && abs(fragment.layout.frame.width - oldArea.width) < 0.5 {
                    var moved = fragment; moved.layout.frame.x = area.x; moved.layout.frame.width = area.width
                    working = try CommandEngine.applying([.replaceBlock(moved)], to: working); commands.append(.replaceBlock(moved))
                }
                if first != story { working = try CommandEngine.applying([.replaceBlock(first)], to: working); commands.append(.replaceBlock(first)) }
                let result = try TextPagination.reflow(first, in: working, selection: NSRange(location: 0, length: 0), incremental: false)
                guard !result.commands.isEmpty else { continue }
                working = try CommandEngine.applying(result.commands, to: working)
                commands += result.commands
            }
            enqueue(commands)
        } catch DocumentError.invalid(let reason) { self.error = reason }
        catch { self.error = String(describing: error) }
    }

    /// A picture for the header or footer from a file: an image as it is, or the first page of a
    /// PDF rendered at print resolution (letterheads often come as PDF).
    func bandAsset(from url: URL) throws -> Asset {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        if let pdf = PDFDocument(data: data), let page = pdf.page(at: 0) {
            let bounds = page.bounds(for: .mediaBox)
            let scale = min(4, 2400 / max(1, max(bounds.width, bounds.height)))
            let format = UIGraphicsImageRendererFormat(); format.scale = 1
            let image = UIGraphicsImageRenderer(size: CGSize(width: bounds.width * scale, height: bounds.height * scale), format: format).image { context in
                UIColor.white.setFill(); context.fill(CGRect(origin: .zero, size: context.format.bounds.size))
                context.cgContext.translateBy(x: 0, y: bounds.height * scale); context.cgContext.scaleBy(x: scale, y: -scale)
                page.draw(with: .mediaBox, to: context.cgContext)
            }
            guard let png = image.pngData() else { throw DocumentError.invalid("Não foi possível ler o PDF.") }
            return try storeAsset(png, mediaType: "image/png")
        }
        guard let image = UIImage(data: data), let png = image.pngData() else { throw DocumentError.invalid("O arquivo não é uma imagem nem um PDF.") }
        return try storeAsset(png, mediaType: "image/png")
    }

    /// The picture without its background: a new PNG asset, same frame, crop and rotation.
    /// The old picture stays registered, so undo brings it back.
    func replaceImage(_ id: UUID, png: Data, pageID: UUID, documentID: UUID) {
        do {
            guard let current = document, current.id == documentID, var block = current.blocks.first(where: { $0.id == id }) else { return }
            let asset = try storeAsset(png, mediaType: "image/png")
            switch block.content {
            case .image(var reference): reference.hash = asset.hash; block.content = .image(reference)
            case .sticker(var reference): reference.hash = asset.hash; block.content = .sticker(reference)
            default: return
            }
            enqueue((current.assets.contains(where: { $0.hash == asset.hash }) ? [] : [.registerAsset(asset)]) + [.replaceBlock(block)],
                    pageID: pageID, documentID: documentID)
        } catch { self.error = String(describing: error) }
    }

    /// Built-in stickers (rendered emoji): no picker, inserted at the first free spot and selected.
    func insertSticker(png data: Data, pageID: UUID, documentID: UUID) {
        do {
            guard let current = document, current.id == documentID, current.pages.contains(where: { $0.id == pageID }) else { return }
            let asset = try storeAsset(data, mediaType: "image/png")
            let spot = freeSpot(width: 120, height: 120, pageID: pageID, in: current)
            let block = CanvasBlock(layout: .init(mode: .absolute, frame: .init(x: spot.x, y: spot.y, width: 120, height: 120)),
                                    content: .sticker(.init(hash: asset.hash)), presentation: .init(wrap: .none))
            enqueue((current.assets.contains(where: { $0.hash == asset.hash }) ? [] : [.registerAsset(asset)]) + [.insertBlock(block)],
                    pageID: pageID, documentID: documentID)
        } catch { self.error = String(describing: error) }
    }

    /// Drawn stickers: a yellow post-it with a text box, or a calendar showing today. Inserted at
    /// the first free spot of the page and selected, like the emoji stickers.
    func insertStickyNote(pageID: UUID, documentID: UUID) {
        guard let current = document, current.id == documentID, current.pages.contains(where: { $0.id == pageID }) else { return }
        let spot = freeSpot(width: Stickers.stickyNoteSide, height: Stickers.stickyNoteSide, pageID: pageID, in: current)
        enqueue(Stickers.stickyNote(at: spot, order: nextRootOrder(in: current)), pageID: pageID, documentID: documentID)
    }
    func insertCalendar(pageID: UUID, documentID: UUID) {
        guard let current = document, current.id == documentID, current.pages.contains(where: { $0.id == pageID }) else { return }
        let spot = freeSpot(width: Stickers.calendarSize.width, height: Stickers.calendarSize.height, pageID: pageID, in: current)
        enqueue(Stickers.calendar(at: spot, order: nextRootOrder(in: current)), pageID: pageID, documentID: documentID)
    }
    /// First free spot from the page's top-left corner (see `Placement`).
    private func freeSpot(width: Double, height: Double, pageID: UUID, in document: CanvasDocument) -> CanvasPoint {
        guard let page = try? document.pageDocument(pageID) else { return .init(x: Placement.margin, y: Placement.margin) }
        return Placement.firstFreeSpot(width: width, height: height, on: page)
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
            let spot = freeSpot(width: 240, height: 340, pageID: pageID, in: document)
            let block = CanvasBlock(layout: .init(mode: .absolute, frame: .init(x: spot.x, y: spot.y, width: 240, height: 340)), content: .pdf(.init(hash: asset.hash, caption: url.lastPathComponent)))
            enqueue((document.assets.contains(where: { $0.hash == asset.hash }) ? [] : [.registerAsset(asset)]) + [.insertBlock(block)], pageID: pageID, documentID: documentID)
        } catch { self.error = String(describing: error) }
    }

    /// Most pages taken from one PDF at a time (each becomes a picture of about 1 MB).
    nonisolated static let pdfPageLimit = 100

    /// Every page of a PDF becomes a page of the note with the PDF page as its background, to write,
    /// draw and type over it. The first PDF page goes on the current page when that page is empty.
    func importPDFPages(_ url: URL, after pageID: UUID, documentID: UUID) async {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            guard let current = document, current.id == documentID, current.kind == .note else { return }
            let data = try Data(contentsOf: url)
            let size = current.canvas.size
            let rendered = try await Task.detached(priority: .userInitiated) { try Self.renderPDFPages(data, fitting: size, limit: Self.pdfPageLimit) }.value
            guard let latest = document, latest.id == documentID, let start = latest.pages.firstIndex(where: { $0.id == pageID }) else { return }
            var commands: [DocumentCommand] = [], registered = Set(latest.assets.map(\.hash))
            // A blank page (nothing on it but, perhaps, an empty text box) takes the first PDF page.
            let reuse = latest.pages[start].background == nil && !latest.blocks.contains { block in
                guard latest.pageID(for: block.id) == pageID else { return false }
                if case .text(let text) = block.content { return !text.plainText.isEmpty }
                return true
            }
            var previous = pageID, first: UUID?
            for (index, picture) in rendered.pages.enumerated() {
                let asset = try storeAsset(picture, mediaType: "image/jpeg")
                if registered.insert(asset.hash).inserted { commands.append(.registerAsset(asset)) }
                if index == 0, reuse {
                    commands.append(.setPageBackground(pageID, asset.hash)); first = pageID
                } else {
                    let page = CanvasPage(title: "\(url.deletingPathExtension().lastPathComponent) – \(index + 1)", background: asset.hash)
                    commands.append(.insertPage(page, after: previous)); previous = page.id
                    if first == nil { first = page.id }
                }
            }
            enqueue(commands)
            if let first, self.document?.pages.contains(where: { $0.id == first }) == true { selectedPageID = first }
            if rendered.total > rendered.pages.count {
                self.error = "O PDF tem \(rendered.total) páginas; foram trazidas as \(rendered.pages.count) primeiras."
            }
        } catch { self.error = String(describing: error) }
    }

    /// JPEG pictures of a PDF's pages, sized to fill the note's page at twice its resolution.
    nonisolated static func renderPDFPages(_ data: Data, fitting size: CanvasSize, limit: Int) throws -> (pages: [Data], total: Int) {
        guard let pdf = PDFDocument(data: data), pdf.pageCount > 0, !pdf.isLocked else { throw DocumentError.invalid("PDF vazio, protegido ou inválido") }
        var pages: [Data] = []
        for index in 0..<min(limit, pdf.pageCount) {
            try autoreleasepool {
                guard let page = pdf.page(at: index) else { return }
                let bounds = page.bounds(for: .mediaBox)
                let rotated = page.rotation % 180 != 0
                let source = CGSize(width: rotated ? bounds.height : bounds.width, height: rotated ? bounds.width : bounds.height)
                guard source.width > 0, source.height > 0 else { return }
                let scale = 2 * min(size.width / source.width, size.height / source.height)
                let picture = page.thumbnail(of: CGSize(width: source.width * scale, height: source.height * scale), for: .mediaBox)
                guard let jpeg = picture.jpegData(compressionQuality: 0.85) else { throw DocumentError.invalid("Não foi possível ler a página \(index + 1) do PDF.") }
                pages.append(jpeg)
            }
        }
        return (pages, pdf.pageCount)
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
                    for stroke in try DrawingStorage.drawing(ref, data: assetData).strokes {
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
        // The page's number in the whole note (the projection holds only that page).
        let pages = document?.pages.map(\.id) ?? []
        return PagePreview.image(document: page, asset: image, drawingData: assetData,
                                 pageIndex: { pages.firstIndex(of: $0) }, pageCount: max(1, pages.count))
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
    @State private var showTrash = false
    @State private var showBacklinks = false
    @State private var showAssistant = false
    /// The floating pen is at the bottom right of an open note (not of a simple note), and the
    /// detail column is what is on screen.
    private var penShown: Bool {
        guard let document = model.document, !document.canvas.isSimpleNote else { return false }
        return preferredColumn == .detail || visibility != .detailOnly
    }
    var body: some View {
        NavigationSplitView(columnVisibility: $visibility, preferredCompactColumn: $preferredColumn) {
            NotesSidebar(model: model, preferredColumn: $preferredColumn, showTrash: $showTrash)
                .navigationSplitViewColumnWidth(min: 320, ideal: 400, max: 520)
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
                                Menu("Adicionar nota à Teia") { ForEach(model.activeSummaries.filter { $0.kind == .note }) { summary in Button(summary.title) { model.addNote(summary) } } }
                            }
                            if document.canvas.solveEquations { Button("Resolver equação digitada") { showEquation = true } }
                            Divider()
                            Button("Exportar traços desta nota", systemImage: "scribble") {
                                do { sharing = ShareFile(url: try model.exportInk(of: document)) }
                                catch let DocumentError.invalid(text) { model.error = text }
                                catch { model.error = String(describing: error) }
                            }
                            Button("Citada em…", systemImage: "link") { showBacklinks = true }.accessibilityIdentifier("backlinks")
                            Button("Medir desempenho do aparelho", systemImage: "speedometer") { showDiagnostics = true }
                        } label: { Image(systemName: "ellipsis.circle") }.accessibilityIdentifier("documentOptions")
                    }
                }
                .sheet(isPresented: $showPage) { PageOptions(settings: document.canvas) { model.applyPageLayout($0) } }
                .sheet(isPresented: $showDiagnostics) { DiagnosticsView() }
                .sheet(isPresented: $showBacklinks) { BacklinksView(model: model, documentID: document.id) }
                .sheet(item: $sharing) { file in ActivitySheet(url: file.url) }
                .alert("Equação de uma incógnita", isPresented: $showEquation) {
                    TextField("Ex.: x² - 5x + 6 = 0", text: $equation)
                    Button("Resolver") { solveEquation(document) }
                    Button("Cancelar", role: .cancel) { }
                } message: { Text("Nesta demonstração, digite ou corrija a expressão. O reconhecimento de equações manuscritas ainda não está conectado.") }
            } else { ContentUnavailableView("Got It!", systemImage: "note.text", description: Text("Crie ou selecione uma nota.")) }
        }
        .sheet(isPresented: $showTrash) { TrashView(model: model) }
        // The assistant, from every screen: above the pen when a note with the pen is open.
        .overlay(alignment: .bottomTrailing) {
            if model.assistant.isAvailable {
                AssistantButton { showAssistant = true }
                    .padding(.trailing, 22)
                    .padding(.bottom, penShown ? 92 : 22)
            }
        }
        .sheet(isPresented: $showAssistant) { AssistantChat(model: model) }
        .onChange(of: model.showListRequest) { _, _ in
            preferredColumn = .sidebar
            visibility = .all
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

/// Deleted notes and Teias, kept whole until restored or deleted for good.
struct TrashView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmEmpty = false
    @State private var deleting: DocumentSummary?
    var body: some View {
        NavigationStack {
            List {
                if model.trashedSummaries.isEmpty {
                    ContentUnavailableView("Lixeira vazia", systemImage: "trash",
                        description: Text("Notas e Teias apagadas ficam aqui até você restaurá-las ou apagá-las para sempre."))
                }
                ForEach(model.trashedSummaries) { summary in
                    HStack(spacing: 12) {
                        if let preview = model.noteMetadata[summary.id]?.preview {
                            Image(uiImage: preview).resizable().scaledToFit().frame(width: 44, height: 56)
                        } else {
                            Image(systemName: summary.kind == .web ? "point.3.connected.trianglepath.dotted" : "note.text")
                                .frame(width: 44, height: 56).foregroundStyle(.secondary)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(summary.title).font(.headline)
                            if let date = summary.trashedAt {
                                Text("Apagada em \(date.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button("Restaurar") { Task { await model.restoreFromTrash(summary.id) } }
                            .buttonStyle(.bordered).accessibilityIdentifier("restore-\(summary.title)")
                    }
                    .swipeActions(edge: .leading, allowsFullSwipe: true) {
                        Button { Task { await model.restoreFromTrash(summary.id) } } label: { Label("Restaurar", systemImage: "arrow.uturn.backward") }
                            .tint(.green)
                    }
                    // Deleting for good asks first; no full swipe.
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button { deleting = summary } label: { Label("Apagar para sempre", systemImage: "trash.slash") }.tint(.red)
                    }
                    .contextMenu {
                        Button("Restaurar", systemImage: "arrow.uturn.backward") { Task { await model.restoreFromTrash(summary.id) } }
                        Button("Apagar para sempre", systemImage: "trash.slash", role: .destructive) { deleting = summary }
                    }
                }
            }
            .navigationTitle("Lixeira")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("OK") { dismiss() } }
                ToolbarItem(placement: .topBarLeading) {
                    Button("Esvaziar", role: .destructive) { confirmEmpty = true }.disabled(model.trashedSummaries.isEmpty)
                }
            }
            .confirmationDialog("Apagar para sempre?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                                titleVisibility: .visible, presenting: deleting) { summary in
                Button("Apagar “\(summary.title)”", role: .destructive) { Task { await model.deleteForever(summary.id) } }
            } message: { _ in Text("Esta ação não pode ser desfeita.") }
            .confirmationDialog("Esvaziar a Lixeira?", isPresented: $confirmEmpty, titleVisibility: .visible) {
                Button("Apagar \(model.trashedSummaries.count) item(ns) para sempre", role: .destructive) { Task { await model.emptyTrash() } }
            } message: { Text("Esta ação não pode ser desfeita.") }
        }
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
                Picker("Margens do texto", selection: Binding(get: { settings.margins == .word ? 1 : 0 }, set: { settings.margins = $0 == 1 ? .word : .legacy })) {
                    Text("Word (2,5 × 3 cm)").tag(1); Text("Estreitas (0,85 cm)").tag(0)
                }
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
