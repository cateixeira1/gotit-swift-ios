import SwiftUI
import UIKit
import GotItDomain
import GotItPersistence

/// The assistant as a chat: the text bar and the keyboard come up at once; above the bar, the
/// suggestions for the open note; "+" chooses the notes to look in.
struct AssistantChat: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var question = ""
    @State private var choosingNotes = false
    @State private var copied: UUID?
    @FocusState private var typing: Bool

    private var assistant: Assistant { model.assistant }
    /// The note on screen, when it is a note (summary and questions need one).
    private var note: CanvasDocument? { model.document.flatMap { $0.kind == .note ? $0 : nil } }

    var body: some View {
        NavigationStack {
            Group {
                if assistant.install == .installed { conversation } else { AssistantModelSetup(assistant: assistant).padding() }
            }
            .navigationTitle("Assistente")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { assistant.cancel(); dismiss() } label: { Image(systemName: "xmark") }.accessibilityLabel("Fechar")
                }
                if !assistant.messages.isEmpty {
                    ToolbarItem(placement: .primaryAction) {
                        Button { assistant.clear() } label: { Image(systemName: "square.and.pencil") }.accessibilityLabel("Nova conversa")
                    }
                }
            }
            .sheet(isPresented: $choosingNotes) { NoteScopePicker(model: model, scope: Binding(get: { assistant.scope }, set: { assistant.scope = $0 })) }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    // MARK: Conversation

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    if assistant.messages.isEmpty {
                        Text(note == nil ? "Pergunte algo sobre as suas notas." : "Pergunte algo sobre as suas notas, ou escolha uma sugestão abaixo.")
                            .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.top, 24)
                    }
                    ForEach(assistant.messages) { message in bubble(message).id(message.id) }
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: assistant.messages.last) { _, last in
                if let last { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(last.id, anchor: .bottom) } }
            }
        }
        .safeAreaInset(edge: .bottom) { inputBar }
        .onAppear { Task { try? await Task.sleep(for: .milliseconds(350)); typing = true } }
    }

    @ViewBuilder private func bubble(_ message: AssistantMessage) -> some View {
        if message.role == .user {
            HStack {
                Spacer(minLength: 48)
                Text(message.text).padding(.horizontal, 14).padding(.vertical, 9)
                    .foregroundStyle(.white).background(Color.accentColor, in: RoundedRectangle(cornerRadius: 18))
            }
        } else {
            HStack {
                VStack(alignment: .leading, spacing: 10) { answer(message) }
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18))
                Spacer(minLength: 32)
            }
        }
    }

    @ViewBuilder private func answer(_ message: AssistantMessage) -> some View {
        if let status = message.status {
            HStack(spacing: 8) { ProgressView(); Text(status).foregroundStyle(.secondary) }
        }
        if !message.text.isEmpty {
            Text(Self.rendered(message.text)).textSelection(.enabled).accessibilityIdentifier("assistantAnswer")
        }
        if let failure = message.failure {
            Label(failure, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary).font(.subheadline)
        }
        if message.noteWasCut {
            Text("A nota é longa: li só o começo (cerca de \(AssistantPrompts.noteLimit / 1000) mil caracteres).")
                .font(.footnote).foregroundStyle(.secondary)
        }
        let done = !message.text.isEmpty && !(assistant.isWorking && message.id == assistant.last?.id)
        if done && !message.sources.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Fontes").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(message.cited, id: \.number) { item in
                    Button {
                        assistant.cancel(); dismiss()
                        Task { await model.openSource(item.source) }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("[\(item.number)] \(item.source.title.isEmpty ? "Sem título" : item.source.title)").font(.footnote.weight(.semibold))
                            Text(item.source.text).font(.caption).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.leading)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        if done {
            HStack(spacing: 18) {
                Button {
                    UIPasteboard.general.string = AssistantPrompts.plainText(withSources(message))
                    copied = message.id
                } label: { Label(copied == message.id ? "Copiado" : "Copiar", systemImage: copied == message.id ? "checkmark" : "doc.on.doc") }
                if let target = message.documentID, target == model.document?.id {
                    Button {
                        Task { if await model.insertAssistantText(withSources(message)) { dismiss() } }
                    } label: { Label("Inserir na nota", systemImage: "text.insert") }
                }
            }
            .font(.footnote).buttonStyle(.borderless)
        }
    }

    // MARK: Text bar

    private var inputBar: some View {
        VStack(spacing: 8) {
            if !assistant.scope.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        Text("Só em:").font(.caption).foregroundStyle(.secondary)
                        ForEach(model.activeSummaries.filter { assistant.scope.contains($0.id) }) { summary in
                            Button { assistant.scope.remove(summary.id) } label: {
                                HStack(spacing: 4) { Text(summary.title).lineLimit(1); Image(systemName: "xmark").font(.caption2.weight(.bold)) }
                                    .font(.caption).padding(.horizontal, 10).padding(.vertical, 5)
                                    .background(Color.accentColor.opacity(0.15), in: Capsule())
                            }
                            .buttonStyle(.plain).accessibilityLabel("Tirar \(summary.title)")
                        }
                    }.padding(.horizontal, 16)
                }
            }
            if let note, !assistant.isWorking {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Assistant.Action.allCases) { action in
                            Button { assistant.run(action, on: note) } label: {
                                Label(action.title, systemImage: action.symbol).font(.subheadline)
                                    .padding(.horizontal, 14).padding(.vertical, 8)
                                    .background(Color(uiColor: .secondarySystemBackground), in: Capsule())
                                    .overlay(Capsule().stroke(Color.primary.opacity(0.08)))
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("assistant-\(action.rawValue)")
                        }
                    }.padding(.horizontal, 16)
                }
            }
            HStack(alignment: .bottom, spacing: 10) {
                Button { choosingNotes = true } label: {
                    Image(systemName: "plus").font(.system(size: 17, weight: .semibold))
                        .frame(width: 36, height: 36)
                        .background(Color(uiColor: .secondarySystemBackground), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Escolher as notas onde procurar")
                TextField("Perguntar às notas", text: $question, axis: .vertical)
                    .lineLimit(1...5)
                    .focused($typing)
                    .submitLabel(.send)
                    .onSubmit(send)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18))
                    .accessibilityIdentifier("assistantQuestion")
                if assistant.isWorking {
                    Button { assistant.cancel() } label: { Image(systemName: "stop.circle.fill").font(.system(size: 32)) }
                        .accessibilityLabel("Parar")
                } else {
                    Button(action: send) { Image(systemName: "arrow.up.circle.fill").font(.system(size: 32)) }
                        .disabled(question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityLabel("Perguntar")
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.vertical, 10)
        .background(.bar)
    }

    private func send() {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !assistant.isWorking else { return }
        question = ""
        let scope = assistant.scope
        assistant.ask(text) { await model.assistantSources(for: text, in: scope) }
    }

    /// The answer, plus where its cited passages came from (for copying or inserting).
    private func withSources(_ message: AssistantMessage) -> String {
        guard !message.sources.isEmpty else { return message.text }
        let list = message.cited.map { "[\($0.number)] \($0.source.title.isEmpty ? "Sem título" : $0.source.title)" }
        return message.text + "\n\nFontes: " + list.joined(separator: "; ")
    }

    /// Bold and italics of the model's Markdown, keeping its line breaks.
    static func rendered(_ markdown: String) -> AttributedString {
        (try? AttributedString(markdown: markdown, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(markdown)
    }
}

/// Choosing the notes the assistant looks in: fewer passages to read, a faster answer.
struct NoteScopePicker: View {
    @Bindable var model: AppModel
    @Binding var scope: Set<UUID>
    @Environment(\.dismiss) private var dismiss
    @State private var filter = ""

    private var notes: [DocumentSummary] {
        let all = model.activeSummaries.filter { $0.kind == .note }
        let text = filter.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? all : all.filter { $0.title.localizedStandardContains(text) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(notes) { summary in
                        Button {
                            if scope.contains(summary.id) { scope.remove(summary.id) } else { scope.insert(summary.id) }
                        } label: {
                            HStack {
                                Image(systemName: scope.contains(summary.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(scope.contains(summary.id) ? Color.accentColor : .secondary)
                                Text(summary.title.isEmpty ? "Sem título" : summary.title).foregroundStyle(.primary)
                                Spacer()
                                if let folder = summary.folderID { Text(model.folderName(folder)).font(.caption).foregroundStyle(.secondary) }
                            }
                            .contentShape(Rectangle())
                        }
                    }
                } footer: {
                    Text("Sem nenhuma escolhida, o assistente procura em todas as notas.")
                }
            }
            .searchable(text: $filter, prompt: "Filtrar notas")
            .navigationTitle(scope.isEmpty ? "Procurar em…" : "\(scope.count) nota(s)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Todas") { scope = [] }.disabled(scope.isEmpty) }
                ToolbarItem(placement: .confirmationAction) { Button("OK") { dismiss() } }
            }
        }
    }
}

/// Downloading the assistant's model (in the chat when it is missing, and in Ajustes).
struct AssistantModelSetup: View {
    var assistant: Assistant

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Resume notas, cria perguntas para revisar e responde perguntas a partir das suas notas, indicando de onde tirou cada informação.")
            Text("Usa o Gemma 4 E2B, do Google (licença Apache 2.0), baixado uma vez (\(assistant.sizeText)). Depois roda no próprio aparelho, sem internet; nada das suas notas sai dele.")
                .foregroundStyle(.secondary).font(.subheadline)
            switch assistant.install {
            case .downloading(let fraction):
                ProgressView(value: fraction) { Text("Baixando o modelo… \(Int(fraction * 100))%") }
                Text("Mantenha o app aberto: a tela fica acesa até terminar. Se parar, o download continua de onde estava.")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("Pausar download", role: .destructive) { assistant.cancelDownload() }
            case .checking:
                ProgressView { Text("Conferindo o arquivo baixado…") }
            case .installed:
                Label("Modelo instalado.", systemImage: "checkmark.circle")
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                downloadButton
            case .absent:
                downloadButton
                Text("Use Wi-Fi: são \(assistant.sizeText).").font(.footnote).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    private var downloadButton: some View {
        Button(assistant.canResume ? "Continuar download" : "Baixar modelo (\(assistant.sizeText))") { assistant.startDownload() }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("downloadAssistant")
    }
}

/// The assistant's round button, at the bottom right of every screen.
struct AssistantButton: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "sparkles")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 52, height: 52)
                .background(Color(uiColor: .systemBackground), in: Circle())
                .shadow(color: .black.opacity(0.22), radius: 6, y: 3)
        }
        .accessibilityLabel("Assistente")
        .accessibilityIdentifier("assistantButton")
    }
}
