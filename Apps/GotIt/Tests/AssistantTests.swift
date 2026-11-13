import XCTest
import GotItDomain
@testable import GotItApp

/// A stand-in for Gemma: writes a fixed answer in pieces, remembering what it was asked.
private actor FakeGenerator: TextGenerator {
    private(set) var prompts: [String] = []
    private(set) var closed = 0
    let answer: [String]
    init(answer: [String]) { self.answer = answer }
    nonisolated func generate(system: String, prompt: String, maxTokens: Int) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                await self.record(prompt)
                for piece in self.answer { continuation.yield(piece); try? await Task.sleep(for: .milliseconds(5)) }
                continuation.finish()
            }
        }
    }
    private func record(_ prompt: String) { prompts.append(prompt) }
    func close() async { closed += 1 }
    func backend() async -> String? { "CPU" }
}

/// The assistant: summary of the open note, questions answered from sources with citations.
@MainActor
final class AssistantTests: XCTestCase {
    private let file = ModelFile(repository: "x/y", revision: "0", fileName: "test-\(UUID()).litertlm", byteCount: 1, sha256: "")

    private func finished(_ assistant: Assistant) async throws {
        for _ in 0..<300 where assistant.isWorking { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(assistant.isWorking)
    }

    func testSummaryAndAQuestionWithItsSources() async throws {
        let generator = FakeGenerator(answer: ["Vence em ", "**março** [2]", "."])
        let assistant = Assistant(modelFile: file, installed: { true }, makeGenerator: { generator })
        XCTAssertEqual(assistant.install, .installed)
        var note = CanvasDocument(title: "Apartamento")
        note.blocks = [CanvasBlock(order: 0, content: .text(RichText("O contrato de locação vence em março.")))]
        assistant.run(.summary, on: note)
        try await finished(assistant)
        XCTAssertEqual(assistant.output, "Vence em **março** [2].")
        var prompts = await generator.prompts
        XCTAssertTrue(prompts.last?.contains("Resuma a nota") == true && prompts.last?.contains("vence em março") == true)
        XCTAssertTrue(assistant.sources.isEmpty)

        let first = AssistantPrompts.Source(documentID: UUID(), blockID: UUID(), title: "Bolo", text: "Receita de bolo.")
        let second = AssistantPrompts.Source(documentID: note.id, blockID: note.blocks[0].id, title: "Apartamento", text: "O contrato vence em março.")
        assistant.ask("Quando vence o contrato?", sources: [first, second])
        try await finished(assistant)
        prompts = await generator.prompts
        XCTAssertTrue(prompts.last?.contains("[2] Nota: Apartamento") == true)
        // Only the passage the answer cites is listed.
        XCTAssertEqual(assistant.citedSources.map(\.number), [2])
        XCTAssertEqual(assistant.citedSources.first?.source, second)

        // Nothing found: no model call, a plain message.
        assistant.ask("Algo?", sources: [])
        XCTAssertNotNil(assistant.failure)
        let calls = await generator.prompts.count
        XCTAssertEqual(calls, 2)
        // An empty note is not sent.
        assistant.run(.questions, on: CanvasDocument(title: "Vazia"))
        XCTAssertFalse(assistant.isWorking)
        XCTAssertNotNil(assistant.failure)

        // Into the background: the model's memory is given back.
        assistant.setActive(false)
        try await Task.sleep(for: .milliseconds(50))
        let closed = await generator.closed
        XCTAssertEqual(closed, 1)
    }

    func testWithoutTheModelNothingIsAsked() async throws {
        let generator = FakeGenerator(answer: ["x"])
        let assistant = Assistant(modelFile: file, installed: { false }, makeGenerator: { generator })
        XCTAssertEqual(assistant.install, .absent)
        var note = CanvasDocument(title: "A")
        note.blocks = [CanvasBlock(order: 0, content: .text(RichText("texto")))]
        assistant.run(.summary, on: note)
        XCTAssertFalse(assistant.isWorking)
        XCTAssertNotNil(assistant.failure)
        let calls = await generator.prompts.count
        XCTAssertEqual(calls, 0)
    }

    /// The real Gemma 4 E2B through LiteRT-LM (on the CPU), when CI provides the model file:
    /// answers a Portuguese question from the passage that has the answer, citing it.
    func testRealGemmaAnswersFromTheRightPassage() async throws {
        guard let path = ProcessInfo.processInfo.environment["GOTIT_ASSISTANT_MODEL"], FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("Modelo não fornecido (GOTIT_ASSISTANT_MODEL).")
        }
        guard let generator = Assistant.liteRT(path: path, allowGPU: { false }) else { throw XCTSkip("LiteRT-LM não existe nesta plataforma.") }
        let sources = [
            AssistantPrompts.Source(documentID: UUID(), blockID: UUID(), title: "Domingo", text: "Bolo de laranja: forno a 180 graus por 40 minutos."),
            AssistantPrompts.Source(documentID: UUID(), blockID: UUID(), title: "Apartamento",
                                    text: "O contrato de locação do apartamento da Rua Augusta vence em 15 de março de 2027. Reajuste pelo IPCA."),
        ]
        let started = Date()
        var answer = "", firstPiece: TimeInterval?
        for try await piece in generator.generate(system: AssistantPrompts.system,
                                                  prompt: AssistantPrompts.question("Quando vence o contrato do apartamento?", sources: sources),
                                                  maxTokens: 120) {
            if firstPiece == nil { firstPiece = Date().timeIntervalSince(started) }
            answer += piece
        }
        let total = Date().timeIntervalSince(started)
        let backend = await generator.backend() ?? "?"
        print("Gemma 4 E2B (\(backend)): first words after \(String(format: "%.1f", firstPiece ?? 0)) s (load included), done in \(String(format: "%.1f", total)) s")
        print("Gemma 4 E2B answer: \(answer)")
        await generator.close()
        XCTAssertTrue(answer.contains("15") && answer.lowercased().contains("março"), answer)
        XCTAssertTrue(AssistantPrompts.citations(in: answer, count: 2).contains(2), answer)
    }
}
