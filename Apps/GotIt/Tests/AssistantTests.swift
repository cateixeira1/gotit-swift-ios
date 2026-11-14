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

    func testConversationWithSummaryAndAQuestionWithItsSources() async throws {
        let generator = FakeGenerator(answer: ["Vence em ", "**março** [2]", "."])
        let assistant = Assistant(modelFile: file, installed: { true }, makeGenerator: { generator })
        XCTAssertEqual(assistant.install, .installed)
        var note = CanvasDocument(title: "Apartamento")
        note.blocks = [CanvasBlock(order: 0, content: .text(RichText("O contrato de locação vence em março.")))]
        assistant.run(.summary, on: note)
        try await finished(assistant)
        XCTAssertEqual(assistant.messages.map(\.role), [.user, .assistant])
        XCTAssertEqual(assistant.messages.first?.text, "Resumir esta nota")
        XCTAssertEqual(assistant.last?.text, "Vence em **março** [2].")
        XCTAssertEqual(assistant.last?.documentID, note.id)
        var prompts = await generator.prompts
        XCTAssertTrue(prompts.last?.contains("Resuma a nota") == true && prompts.last?.contains("vence em março") == true)

        let first = AssistantPrompts.Source(documentID: UUID(), blockID: UUID(), title: "Bolo", text: "Receita de bolo.")
        let second = AssistantPrompts.Source(documentID: note.id, blockID: note.blocks[0].id, title: "Apartamento", text: "O contrato vence em março.")
        assistant.ask("Quando vence o contrato?") { return [first, second] }
        XCTAssertEqual(assistant.last?.status, "Procurando nas notas…")
        try await finished(assistant)
        prompts = await generator.prompts
        XCTAssertTrue(prompts.last?.contains("[2] Nota: Apartamento") == true)
        XCTAssertEqual(assistant.messages.count, 4)
        XCTAssertEqual(assistant.messages[2].text, "Quando vence o contrato?")
        // Only the passage the answer cites is listed.
        XCTAssertEqual(assistant.last?.cited.map(\.number), [2])
        XCTAssertEqual(assistant.last?.cited.first?.source, second)
        XCTAssertNil(assistant.last?.documentID)

        // Nothing found: no model call, a plain message.
        assistant.ask("Algo?") { return [] }
        try await finished(assistant)
        XCTAssertNotNil(assistant.last?.failure)
        let calls = await generator.prompts.count
        XCTAssertEqual(calls, 2)
        // An empty note is not sent.
        assistant.run(.questions, on: CanvasDocument(title: "Vazia"))
        XCTAssertFalse(assistant.isWorking)
        XCTAssertNotNil(assistant.last?.failure)
        assistant.clear()
        XCTAssertTrue(assistant.messages.isEmpty)

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
        XCTAssertNotNil(assistant.last?.failure)
        let calls = await generator.prompts.count
        XCTAssertEqual(calls, 0)
    }

    /// The real Gemma 4 E2B through LiteRT-LM (on the CPU), when CI provides the model file:
    /// answers a Portuguese question from the passage that has the answer, citing it, and keeps
    /// answering after the first time (a second conversation on the same engine, and a new engine
    /// over the cache the first one left). Each case is printed, to see which one LiteRT-LM fails.
    func testRealGemmaAnswersFromTheRightPassageMoreThanOnce() async throws {
        guard let path = ProcessInfo.processInfo.environment["GOTIT_ASSISTANT_MODEL"], FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("Modelo não fornecido (GOTIT_ASSISTANT_MODEL).")
        }
        guard Assistant.liteRT(path: path) != nil else { throw XCTSkip("LiteRT-LM não existe nesta plataforma.") }
        let sources = [
            AssistantPrompts.Source(documentID: UUID(), blockID: UUID(), title: "Domingo", text: "Bolo de laranja: forno a 180 graus por 40 minutos."),
            AssistantPrompts.Source(documentID: UUID(), blockID: UUID(), title: "Apartamento",
                                    text: "O contrato de locação do apartamento da Rua Augusta vence em 15 de março de 2027. Reajuste pelo IPCA."),
        ]
        let question = AssistantPrompts.question("Quando vence o contrato do apartamento?", sources: sources)
        let summary = AssistantPrompts.summary(title: "Apartamento", text: sources[1].text, truncated: false)
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("litert-cache-\(UUID())")
        defer { try? FileManager.default.removeItem(at: cache) }

        func ask(_ generator: any TextGenerator, _ prompt: String, _ label: String) async -> String? {
            let started = Date()
            var answer = ""
            do {
                for try await piece in generator.generate(system: AssistantPrompts.system, prompt: prompt, maxTokens: 120) { answer += piece }
                print("Gemma 4 E2B [\(label)] OK em \(String(format: "%.1f", Date().timeIntervalSince(started))) s: \(answer)")
                return answer
            } catch {
                print("Gemma 4 E2B [\(label)] ERRO em \(String(format: "%.1f", Date().timeIntervalSince(started))) s: \(error)")
                return nil
            }
        }

        // Without retrying: each case must work by itself. (On the CPU all of them do; on a
        // device's GPU the second conversation failed with "No per-layer embeddings found".)
        let first = Assistant.liteRT(path: path, allowGPU: { false }, cacheDirectory: cache, retry: false)!
        let answer = await ask(first, question, "1ª conversa, cache vazio")
        XCTAssertTrue(answer?.contains("15") == true && answer?.lowercased().contains("março") == true, answer ?? "erro")
        XCTAssertTrue(AssistantPrompts.citations(in: answer ?? "", count: 2).contains(2), answer ?? "erro")
        let second = await ask(first, summary, "2ª conversa, mesmo motor")
        XCTAssertNotNil(second)
        let third = await ask(first, question, "3ª conversa, mesmo motor")
        XCTAssertNotNil(third)
        await first.close()
        let warm = Assistant.liteRT(path: path, allowGPU: { false }, cacheDirectory: cache, retry: false)!
        let again = await ask(warm, question, "motor novo, cache já preenchido")
        XCTAssertNotNil(again)
        await warm.close()
    }
}
