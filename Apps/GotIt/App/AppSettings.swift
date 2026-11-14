import SwiftUI
import GotItCanvasUI

/// Ajustes: what the app opens on, the default font, and the on-device models (search by meaning
/// and the assistant).
struct AppSettingsView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var fontName: String? = AppFonts.defaultName

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Abrir em", selection: Binding(get: { model.launchTarget }, set: { model.launchTarget = $0 })) {
                        ForEach(AppModel.LaunchTarget.allCases) { target in Text(target.title).tag(target) }
                    }
                    .accessibilityIdentifier("launchTarget")
                } header: { Text("Ao abrir o app") }

                Section {
                    Picker("Fonte padrão", selection: $fontName) {
                        ForEach(AppFonts.choices, id: \.title) { choice in
                            Text(choice.title).font(choice.name.map { Font.custom($0, size: 17) } ?? Font.body).tag(choice.name)
                        }
                    }
                    .pickerStyle(.navigationLink)
                    .accessibilityIdentifier("defaultFont")
                    Text("O texto sem fonte escolhida aparece nesta fonte, nas notas novas e nas que já existem. Texto em que você escolheu uma fonte fica como está.")
                        .font(.footnote).foregroundStyle(.secondary)
                } header: { Text("Texto") }
                .onChange(of: fontName) { _, name in
                    AppFonts.setDefault(name)
                    Task { await model.defaultFontChanged() }
                }

                Section {
                    if model.semantic.isAvailable {
                        NavigationLink {
                            SemanticSearchSettings(search: model.semantic)
                        } label: {
                            LabeledContent { Text(SemanticSearchSettings.shortStatus(model.semantic)) } label: {
                                Label("Busca por significado", systemImage: "sparkle.magnifyingglass")
                            }
                        }
                        .accessibilityIdentifier("semanticSearch")
                    }
                    if model.assistant.isAvailable {
                        NavigationLink {
                            AssistantSettings(assistant: model.assistant)
                        } label: {
                            LabeledContent { Text(model.assistant.install == .installed ? "Gemma 4" : "Falta o modelo") } label: {
                                Label("Assistente", systemImage: "sparkles")
                            }
                        }
                        .accessibilityIdentifier("assistantSettings")
                    }
                } header: { Text("Inteligência no aparelho") } footer: {
                    if !model.semantic.isAvailable { Text("Os modelos no aparelho não estão disponíveis no Mac.") }
                }
            }
            .navigationTitle("Ajustes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("OK") { dismiss() } } }
        }
    }
}

/// Ajustes › Assistente: the model, the GPU, removing the model.
struct AssistantSettings: View {
    var assistant: Assistant
    @State private var confirmRemoval = false

    var body: some View {
        Form {
            Section { AssistantModelSetup(assistant: assistant).padding(.vertical, 4) }
            if assistant.install == .installed {
                Section {
                    Toggle("Usar a GPU", isOn: Binding(get: { assistant.useGPU }, set: { assistant.useGPU = $0 }))
                    if assistant.useGPU && assistant.gpuFailed {
                        Text("A GPU não funcionou da última vez (falha ao carregar, ou o sistema fechou o app por falta de memória): o assistente está usando o processador.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("Desligado, o assistente usa o processador: mais lento, mas a versão atual do LiteRT-LM tem um problema aberto com números escritos pelo Gemma 4 na GPU do iPhone.")
                }
                Section {
                    Button("Apagar o modelo (\(assistant.sizeText))", role: .destructive) { confirmRemoval = true }
                        .accessibilityIdentifier("removeAssistantModel")
                } footer: {
                    Text("As notas não são afetadas; para voltar a usar, o modelo é baixado de novo.")
                }
            }
        }
        .navigationTitle("Assistente")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Apagar o modelo do assistente?", isPresented: $confirmRemoval, titleVisibility: .visible) {
            Button("Apagar (\(assistant.sizeText))", role: .destructive) { Task { await assistant.removeModel() } }
        }
    }
}
