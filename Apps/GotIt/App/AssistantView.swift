import SwiftUI
import UIKit
import GotItDomain

/// The assistant's sheet: getting the model, then summarizing or making review questions of the
/// open note, or answering a question from the notes, with the passages it used.
struct AssistantView: View {
    @Bindable var model: AppModel
    /// The note on screen, if any (summary and questions need one).
    let document: CanvasDocument?
    @Environment(\.dismiss) private var dismiss
    @State private var question = ""
    @State private var lastAction: Assistant.Action?
    @State private var confirmRemoval = false
    @State private var copied = false
    @FocusState private var typing: Bool

    private var assistant: Assistant { model.assistant }
    private var hasNote: Bool { document.map { $0.kind == .note } ?? false }

    var body: some View {
        NavigationStack {
            Form {
                switch assistant.install {
                case .installed: ready
                default: setup
                }
            }
            .navigationTitle("Assistente")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("OK") { assistant.cancel(); dismiss() } }
            }
            .confirmationDialog("Apagar o modelo do assistente?", isPresented: $confirmRemoval, titleVisibility: .visible) {
                Button("Apagar (\(assistant.sizeText))", role: .destructive) { Task { await assistant.removeModel() } }
            } message: {
                Text("As notas não são afetadas; para voltar a usar, o modelo é baixado de novo.")
            }
        }
    }

    // MARK: Getting the model

    @ViewBuilder private var setup: some View {
        Section {
            Text("Resume notas, cria perguntas para revisar e responde perguntas a partir das suas notas, indicando de onde tirou cada informação.")
            Text("Usa o Gemma 4 E2B, do Google (licença Apache 2.0), baixado uma vez (\(assistant.sizeText)). Depois roda no próprio aparelho, sem internet; nada das suas notas sai dele.")
                .foregroundStyle(.secondary)
        }
        Section {
            switch assistant.install {
            case .downloading(let fraction):
                ProgressView(value: fraction) { Text("Baixando o modelo… \(Int(fraction * 100))%") }
                Text("Mantenha o app aberto: a tela fica acesa até terminar. Se parar, o download continua de onde estava.")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("Pausar download", role: .destructive) { assistant.cancelDownload() }
            case .checking:
                ProgressView { Text("Conferindo o arquivo baixado…") }
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                downloadButton
            default:
                downloadButton
                Text("Use Wi-Fi: são \(assistant.sizeText).").font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private var downloadButton: some View {
        Button(assistant.canResume ? "Continuar download" : "Baixar modelo (\(assistant.sizeText))") { assistant.startDownload() }
            .accessibilityIdentifier("downloadAssistant")
    }

    // MARK: Using it

    @ViewBuilder private var ready: some View {
        if hasNote, let document {
            Section {
                ForEach([Assistant.Action.summary, .questions]) { action in
                    Button { lastAction = action; assistant.run(action, on: document) } label: { Label(action.title, systemImage: action.symbol) }
                        .disabled(assistant.isWorking)
                }
            } header: { Text(document.title.isEmpty ? "Esta nota" : document.title) }
        }
        Section {
            if model.semantic.canSearch {
                HStack {
                    TextField("Ex.: quando vence o contrato?", text: $question, axis: .vertical)
                        .lineLimit(1...4).focused($typing).submitLabel(.send).onSubmit(send)
                        .accessibilityIdentifier("assistantQuestion")
                    Button(action: send) { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                        .disabled(question.trimmingCharacters(in: .whitespaces).isEmpty || assistant.isWorking)
                        .accessibilityLabel("Perguntar")
                }
            } else {
                Text("Para perguntar às notas, o assistente precisa achar os trechos certos: ligue a busca por significado (165 MB).")
                    .foregroundStyle(.secondary)
                if model.semantic.state == .off || model.semantic.state == .needsModel {
                    Button("Ligar busca por significado") { model.semantic.enable() }
                } else {
                    Text("Busca por significado: \(SemanticSearchSettings.shortStatus(model.semantic))").font(.footnote)
                }
            }
        } header: { Text(Assistant.Action.ask.title) }

        if assistant.isWorking || !assistant.output.isEmpty || assistant.failure != nil { answer }

        Section {
            Toggle("Usar a GPU (mais rápido)", isOn: Binding(get: { assistant.useGPU }, set: { assistant.useGPU = $0 }))
            if assistant.gpuFailed && assistant.useGPU {
                Text("A GPU não funcionou da última vez (falha ao carregar, ou o sistema fechou o app por falta de memória): o assistente está usando o processador. Ligue de novo para tentar a GPU.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Button("Apagar o modelo (\(assistant.sizeText))", role: .destructive) { confirmRemoval = true }
        } footer: {
            Text("Roda no aparelho\(assistant.backend.map { " (\($0))" } ?? ""). O modelo pode errar ou omitir coisas: confira na nota antes de usar.")
        }
    }

    @ViewBuilder private var answer: some View {
        Section {
            if assistant.isLoading {
                ProgressView { Text("Preparando o modelo… (alguns segundos na primeira vez)") }
            }
            if !assistant.output.isEmpty {
                Text(Self.rendered(assistant.output)).textSelection(.enabled).accessibilityIdentifier("assistantAnswer")
            }
            if let failure = assistant.failure {
                Label(failure, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
            }
            if assistant.isWorking {
                Button("Parar", role: .destructive) { assistant.cancel() }
            } else if !assistant.output.isEmpty {
                Button { UIPasteboard.general.string = AssistantPrompts.plainText(assistant.output); copied = true } label: {
                    Label(copied ? "Copiado" : "Copiar", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                if hasNote, document?.id == model.document?.id {
                    Button {
                        Task { if await model.insertAssistantText(withSources(assistant.output)) { dismiss() } }
                    } label: { Label("Inserir na nota", systemImage: "text.insert") }
                }
            }
            if assistant.noteWasCut {
                Text("A nota é longa: o assistente leu só o começo (cerca de \(AssistantPrompts.noteLimit / 1000) mil caracteres).")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        } header: { Text(lastAction?.title ?? "Resposta") }

        if !assistant.isWorking, !assistant.sources.isEmpty {
            Section {
                ForEach(assistant.citedSources, id: \.number) { item in
                    Button {
                        assistant.cancel()
                        dismiss()
                        Task { await model.openSource(item.source) }
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("[\(item.number)] \(item.source.title.isEmpty ? "Sem título" : item.source.title)").font(.subheadline.weight(.semibold))
                            Text(item.source.text).font(.footnote).foregroundStyle(.secondary).lineLimit(3)
                        }
                    }
                }
            } header: { Text("Fontes") } footer: { Text("Toque para abrir a nota no trecho.") }
        }
    }

    private func send() {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !assistant.isWorking else { return }
        typing = false
        lastAction = .ask
        copied = false
        Task { assistant.ask(text, sources: await model.assistantSources(for: text)) }
    }

    /// The answer, plus where its cited passages came from (for inserting in a note).
    private func withSources(_ text: String) -> String {
        guard !assistant.sources.isEmpty else { return text }
        let list = assistant.citedSources.map { "[\($0.number)] \($0.source.title.isEmpty ? "Sem título" : $0.source.title)" }
        return text + "\n\nFontes: " + list.joined(separator: "; ")
    }

    /// Bold and italics of the model's Markdown, keeping its line breaks.
    static func rendered(_ markdown: String) -> AttributedString {
        (try? AttributedString(markdown: markdown, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(markdown)
    }
}

/// The assistant's round button, above the pen.
struct AssistantButton: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "sparkles")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 50, height: 50)
                .background(Color(uiColor: .systemBackground), in: Circle())
                .shadow(color: .black.opacity(0.22), radius: 6, y: 3)
        }
        .accessibilityLabel("Assistente")
        .accessibilityIdentifier("assistantButton")
    }
}
