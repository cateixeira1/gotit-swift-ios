import SwiftUI
import GotItDomain
import GotItPersistence

/// The list of notes and Teias, by folder: the folder being shown, its subfolders, then what is
/// filed in it. New notes go into the folder shown. Folders are only filing: moving a note in or
/// out never changes the note, and deleting a folder moves what it holds up to its parent.
struct NotesSidebar: View {
    @Bindable var model: AppModel
    @Binding var preferredColumn: NavigationSplitViewColumn
    @Binding var showTrash: Bool

    private enum NameRequest: Identifiable {
        case create, rename(Folder)
        var id: String { if case .rename(let folder) = self { "rename-\(folder.id)" } else { "create" } }
    }
    @State private var naming: NameRequest?
    @State private var name = ""
    @State private var deleting: Folder?
    @State private var query = ""
    @State private var results: [AppModel.SearchResult] = []
    @State private var meaning: [AppModel.SearchResult] = []
    @State private var showSettings = false
    private var searching: Bool { SearchText.query(query) != nil }

    var body: some View {
        List {
            if searching {
                Section {
                    if results.isEmpty && meaning.isEmpty {
                        Text("Nada encontrado para “\(query.trimmingCharacters(in: .whitespaces))”.").foregroundStyle(.secondary)
                            .accessibilityIdentifier("searchEmpty")
                    }
                    ForEach(results) { result in resultRow(result) }
                } header: { Text("Resultados") } footer: {
                    Text("Procura no título, no texto, em post-its, transcrições, tabelas e legendas, em todas as pastas. Escrita à mão entra na busca depois de convertida em texto.")
                }
                if !meaning.isEmpty {
                    Section {
                        ForEach(meaning) { result in resultRow(result) }
                    } header: { Text("Por significado") } footer: {
                        Text("Notas sobre o mesmo assunto, mesmo sem as palavras buscadas. Calculado no próprio aparelho.")
                    }
                }
            } else {
            Section {
                if let current = model.folder(model.currentFolder) {
                    Button { model.currentFolder = current.parentID } label: {
                        Label("Voltar para \(model.folderName(current.parentID))", systemImage: "chevron.backward")
                    }.accessibilityIdentifier("folderBack")
                }
                Button("Nova nota", systemImage: "plus") { Task { await model.createNote(); preferredColumn = .detail } }
                Button("Nova nota simples", systemImage: "note.text") { Task { await model.createSimpleNote(); preferredColumn = .detail } }
                    .accessibilityIdentifier("newSimpleNote")
                Button("Nova Teia", systemImage: "point.3.connected.trianglepath.dotted") { Task { await model.createWeb(); preferredColumn = .detail } }
                Button("Nova pasta", systemImage: "folder.badge.plus") { name = ""; naming = .create }
                    .accessibilityIdentifier("newFolder")
                ForEach(model.subfolders(of: model.currentFolder)) { folder in folderRow(folder) }
            } header: { Text(model.currentFolder == nil ? "Notas e Teias" : model.folderName(model.currentFolder)) }
            if !model.visibleSummaries.isEmpty {
                Section { documentGrid }
            }
            Section {
                Button { showTrash = true } label: {
                    HStack {
                        Label("Lixeira", systemImage: "trash")
                        Spacer()
                        if !model.trashedSummaries.isEmpty { Text("\(model.trashedSummaries.count)").foregroundStyle(.secondary) }
                    }
                }.accessibilityIdentifier("openTrash")
                Button { showSettings = true } label: { Label("Ajustes", systemImage: "gearshape") }
                    .accessibilityIdentifier("openSettings")
            } footer: {
                HStack(spacing: 8) {
                    Image("LaunchLogo").resizable().frame(width: 22, height: 22)
                    Text("Color Software").font(.footnote.weight(.medium)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity).padding(.top, 28)
                .accessibilityElement(children: .combine)
            }
            }
        }
        .searchable(text: $query, placement: .sidebar, prompt: "Buscar nas notas")
        .task(id: query) {
            // A short pause after typing, then the index is asked (it answers in milliseconds).
            guard searching else { results = []; meaning = []; return }
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            let found = await model.search(query)
            guard !Task.isCancelled else { return }
            results = found
            // By meaning: the model reads the query (tens of milliseconds), so a little later.
            guard model.semantic.canSearch else { meaning = []; return }
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            let related = await model.searchByMeaning(query, excluding: Set(found.map(\.documentID)))
            if !Task.isCancelled { meaning = related }
        }
        .sheet(isPresented: $showSettings) { AppSettingsView(model: model) }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showSettings = true } label: { Image(systemName: "gearshape") }.accessibilityLabel("Ajustes")
            }
        }
        .navigationTitle(model.currentFolder == nil ? "Got It!" : model.folderName(model.currentFolder))
        // A deleted row (already faded) closes its gap smoothly instead of vanishing.
        .animation(.easeOut(duration: 0.2), value: model.visibleSummaries.map(\.id))
        .animation(.easeOut(duration: 0.2), value: model.currentFolder)
        .disabled(model.isSaving)
        .alert(namingTitle, isPresented: Binding(get: { naming != nil }, set: { if !$0 { naming = nil } })) {
            TextField("Nome da pasta", text: $name).accessibilityIdentifier("folderName")
            Button(namingAction) {
                let request = naming, chosen = name
                Task {
                    switch request {
                    case .create: await model.createFolder(named: chosen)
                    case .rename(let folder): await model.renameFolder(folder.id, to: chosen)
                    case nil: break
                    }
                }
            }
            Button("Cancelar", role: .cancel) { }
        }
        .confirmationDialog("Apagar a pasta?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible, presenting: deleting) { folder in
            Button("Apagar “\(folder.name)”", role: .destructive) { Task { await model.deleteFolder(folder.id) } }
        } message: { folder in
            Text("As notas, Teias e pastas de dentro vão para “\(model.folderName(folder.parentID))”. Nenhuma nota é apagada.")
        }
    }

    private var namingTitle: String { if case .rename = naming { "Renomear pasta" } else { "Nova pasta" } }
    private var namingAction: String { if case .rename = naming { "Renomear" } else { "Criar" } }

    private func resultRow(_ result: AppModel.SearchResult) -> some View {
        Button { Task { await model.open(result, query: query); preferredColumn = .detail } } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: result.kind == .web ? "point.3.connected.trianglepath.dotted" : "note.text").foregroundStyle(.secondary)
                    Text(result.title).font(.headline).lineLimit(1)
                    Spacer()
                    if result.matches > 1 { Text("\(result.matches)").font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                }
                if result.hit.kind != .title { Text(Self.highlighted(result.hit.snippet)).font(.subheadline).lineLimit(3) }
                if let folder = result.folder { Label(folder, systemImage: "folder").font(.caption).foregroundStyle(.secondary) }
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("searchResult-\(result.title)")
    }

    /// The excerpt with the words found in bold.
    static func highlighted(_ snippet: String) -> AttributedString {
        var output = AttributedString()
        var bold = false, piece = ""
        func flush() {
            guard !piece.isEmpty else { return }
            var part = AttributedString(piece)
            if bold { part.inlinePresentationIntent = .stronglyEmphasized; part.foregroundColor = .accentColor }
            output += part; piece = ""
        }
        for character in snippet.replacingOccurrences(of: "\n", with: " ") {
            if character == SearchHit.markStart { flush(); bold = true }
            else if character == SearchHit.markEnd { flush(); bold = false }
            else { piece.append(character) }
        }
        flush()
        return output
    }

    private func folderRow(_ folder: Folder) -> some View {
        Button { model.currentFolder = folder.id } label: {
            HStack {
                Label(folder.name, systemImage: "folder").foregroundStyle(.primary)
                Spacer()
                Text("\(model.count(in: folder.id))").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                Image(systemName: "chevron.forward").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
        }
        .contextMenu {
            Button("Renomear", systemImage: "pencil") { name = folder.name; naming = .rename(folder) }
            moveMenu(excluding: model.descendants(of: folder.id), current: folder.parentID) { target in
                Task { await model.moveFolder(folder.id, to: target) }
            }
            Button("Apagar pasta", systemImage: "trash", role: .destructive) { deleting = folder }
        }
        .accessibilityIdentifier("folder-\(folder.name)")
    }

    /// Notes and Teias three to a row, each a page preview with its title and date; the whole
    /// tile opens it, a long press offers moving, a Teia and deleting.
    private var documentGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14, alignment: .top), count: 3), spacing: 18) {
            ForEach(model.visibleSummaries) { summary in documentTile(summary).transition(.opacity) }
        }
        .padding(.vertical, 6)
        .listRowInsets(EdgeInsets(top: 8, leading: 14, bottom: 8, trailing: 14))
        .listRowBackground(Color.clear)
    }

    private func documentTile(_ summary: DocumentSummary) -> some View {
        Button { Task { await model.open(summary.id); preferredColumn = .detail } } label: {
            VStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10).fill(Color(uiColor: .secondarySystemGroupedBackground))
                    if let preview = model.noteMetadata[summary.id]?.preview {
                        Image(uiImage: preview).resizable().scaledToFit().padding(5)
                    } else {
                        Image(systemName: summary.kind == .web ? "point.3.connected.trianglepath.dotted" : "note.text")
                            .font(.system(size: 30)).foregroundStyle(.secondary)
                    }
                }
                .aspectRatio(0.78, contentMode: .fit)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(model.document?.id == summary.id ? Color.accentColor : Color.primary.opacity(0.1),
                                                                    lineWidth: model.document?.id == summary.id ? 2 : 1))
                .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
                Text(summary.title.isEmpty ? "Sem título" : summary.title)
                    .font(.footnote.weight(.semibold)).lineLimit(2).multilineTextAlignment(.center)
                Text(summary.createdAt, format: .dateTime.day().month(.abbreviated).year(.twoDigits))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        // Plain: each tile in the row is its own button (a default button fires the whole row).
        .buttonStyle(.plain)
        .contextMenu {
            if summary.kind == .note {
                Button("Criar Teia com esta nota", systemImage: "point.3.connected.trianglepath.dotted") {
                    Task { await model.createWeb(including: summary.id); preferredColumn = .detail }
                }
            }
            moveMenu(excluding: [], current: summary.folderID) { target in Task { await model.moveDocument(summary.id, to: target) } }
            Button("Apagar", systemImage: "trash", role: .destructive) { Task { await model.moveToTrash(summary.id) } }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("document-\(summary.title)")
    }

    /// "Mover para": the top level and every folder (indented under its parent), except where the
    /// item already is and, for a folder, itself and its subfolders.
    private func moveMenu(excluding excluded: Set<UUID>, current: UUID?, move: @escaping (UUID?) -> Void) -> some View {
        Menu("Mover para", systemImage: "folder") {
            Button("Início (fora das pastas)", systemImage: "house") { move(nil) }.disabled(current == nil)
            ForEach(model.folderTree.filter { !excluded.contains($0.folder.id) }) { item in
                Button(String(repeating: "    ", count: item.depth) + item.folder.name, systemImage: "folder") { move(item.folder.id) }
                    .disabled(item.folder.id == current)
            }
        }
    }
}
