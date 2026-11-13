import XCTest
import GotItDomain
import GotItPersistence
@testable import GotItApp

/// A stand-in for EmbeddingGemma: one axis per known subject, so texts on one subject are close.
private actor FakeEmbedder: TextEmbedder {
    private(set) var calls = 0
    private(set) var closed = 0
    func embed(_ text: String) async throws -> [Float] {
        calls += 1
        let subjects = [["aluguel", "locação", "inquilino"], ["bolo", "receita", "forno"], ["hospital", "laudo", "médico"]]
        let lower = text.lowercased()
        return SemanticChunks.normalized(subjects.map { words in words.contains { lower.contains($0) } ? 1 : 0 } + [0.05])
    }
    func close() async { closed += 1 }
}

/// The search by meaning: reading the notes into vectors, following edits, answering by subject.
@MainActor
final class SemanticSearchTests: XCTestCase {
    private func wait(_ search: SemanticSearch, until done: (SemanticSearch.State) -> Bool) async throws {
        for _ in 0..<500 where !done(search.state) { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(done(search.state), "state: \(search.state)")
    }

    private func wait(for calls: Int, _ embedder: FakeEmbedder, _ search: SemanticSearch) async throws {
        for _ in 0..<500 {
            if await embedder.calls >= calls, search.state == .ready { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let made = await embedder.calls
        XCTAssertEqual(made, calls)
        XCTAssertEqual(search.state, .ready)
    }

    func testNotesAreReadAndFoundBySubjectThenFollowEdits() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("semantic-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let wasEnabled = UserDefaults.standard.bool(forKey: SemanticSearch.enabledKey)
        defer {
            UserDefaults.standard.set(wasEnabled, forKey: SemanticSearch.enabledKey)
            try? FileManager.default.removeItem(at: directory)
        }
        let store = try SQLiteStore(url: directory.appendingPathComponent("notes.sqlite"))
        func story(_ text: String) -> CanvasBlock {
            var block = CanvasBlock(layout: .init(mode: .absolute, frame: .init(x: 80, y: 80, width: 300, height: 44)), content: .text(RichText(text)))
            block.textFlowID = block.id
            return block
        }
        let rent = try await store.create(CanvasDocument(title: "Apartamento"))
        let rentText = story("O inquilino pediu para renovar a locação por mais um ano.")
        let edited = try await store.execute([.insertBlock(rentText)], documentID: rent.id, expectedRevision: 0)
        let cake = try await store.create(CanvasDocument(title: "Domingo"))
        _ = try await store.execute([.insertBlock(story("Bolo de laranja: forno a 180 graus por 40 minutos."))], documentID: cake.id, expectedRevision: 0)

        let embedder = FakeEmbedder()
        let search = SemanticSearch(model: "fake", modelInstalled: { true }, makeEmbedder: { embedder })
        UserDefaults.standard.set(false, forKey: SemanticSearch.enabledKey)
        search.attach(store)
        XCTAssertEqual(search.state, .off)
        let nothing = await search.search("aluguel")
        XCTAssertTrue(nothing.isEmpty, "off: nothing is searched")

        search.enable()
        try await wait(search) { $0 == .ready }
        let read = await embedder.calls
        XCTAssertEqual(read, 2, "one passage per note")
        // "aluguel" is in neither note; the note on the subject is found.
        var hits = await search.search("contrato de aluguel")
        XCTAssertEqual(hits.first?.documentID, rent.id)
        XCTAssertEqual(hits.first?.blockID, rentText.id)
        hits = await search.search("receita de sobremesa")
        XCTAssertEqual(hits.first?.documentID, cake.id)

        // An edit is read again (only what changed), and the search follows it.
        var changed = rentText; changed.content = .text(RichText("Laudo do médico do hospital."))
        _ = try await store.execute([.replaceBlock(changed)], documentID: rent.id, expectedRevision: edited.revision)
        search.retry()
        // Two queries, then only the changed passage.
        try await wait(for: read + 2 + 1, embedder, search)
        hits = await search.search("exame no hospital")
        XCTAssertEqual(hits.first?.documentID, rent.id)

        // Into the background: the model's memory is given back; off: nothing more is searched.
        search.setActive(false)
        try await Task.sleep(for: .milliseconds(50))
        let closed = await embedder.closed
        XCTAssertEqual(closed, 1)
        search.setActive(true)
        try await wait(search) { $0 == .ready }
        await search.disable(removingModel: false)
        XCTAssertEqual(search.state, .off)
        XCTAssertFalse(search.isEnabled)
        let off = await search.search("hospital")
        XCTAssertTrue(off.isEmpty)
        try await store.close()
    }

    /// The real EmbeddingGemma 2 through LiteRT-LM, when CI (or a developer) provides the model
    /// file: vectors of the size asked, of length 1, and Portuguese queries closest to the note on
    /// their subject. The scores are printed, to set the thresholds of the search.
    func testRealModelFindsPortugueseNotesBySubject() async throws {
        guard let path = ProcessInfo.processInfo.environment["GOTIT_EMBEDDING_MODEL"], FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("Modelo não fornecido (GOTIT_EMBEDDING_MODEL).")
        }
        guard let embedder = SemanticSearch.liteRT(path: path) else { throw XCTSkip("LiteRT-LM não existe nesta plataforma.") }
        let notes = [
            ("Apartamento", "O inquilino pediu para renovar a locação por mais um ano."),
            ("Domingo", "Bolo de laranja: forno a 180 graus por 40 minutos."),
            ("Consulta", "O médico pediu exames de sangue e um raio-x do joelho."),
            ("Processo", "Petição inicial da ação de indenização por danos morais contra a companhia aérea."),
        ]
        let queries = ["contrato de aluguel", "receita de sobremesa", "exame no hospital", "voo atrasado processo"]
        let started = Date()
        var vectors: [[Float]] = []
        for note in notes { vectors.append(try await embedder.embed(SemanticChunks.documentPrompt(title: note.0, text: note.1))) }
        print("EmbeddingGemma: \(notes.count) passages in \(Int(Date().timeIntervalSince(started) * 1000)) ms (load included)")
        for vector in vectors {
            XCTAssertEqual(vector.count, EmbeddingModel.dimensions)
            XCTAssertEqual(SemanticChunks.similarity(vector, vector), 1, accuracy: 0.01)
        }
        for (expected, query) in queries.enumerated() {
            let vector = try await embedder.embed(SemanticChunks.queryPrompt(query))
            let scores = vectors.map { SemanticChunks.similarity(vector, $0) }
            print("EmbeddingGemma: “\(query)” → " + scores.map { String(format: "%.3f", $0) }.joined(separator: " "))
            XCTAssertEqual(scores.firstIndex(of: scores.max()!), expected, "“\(query)”: \(scores)")
        }
        await embedder.close()
    }

    /// The model file is checked against its published size and SHA-256 before use.
    func testADamagedModelFileIsRejected() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("model-\(UUID()).litertlm")
        try Data("not a model".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertFalse(try EmbeddingModel.verify(url))
    }
}
