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
        /// "Nova pasta"; renaming a folder; naming the folder a drop just made (it already has the
        /// generic name, kept when nothing is typed).
        case create, rename(Folder), fresh(Folder)
        var id: String {
            switch self {
            case .create: "create"
            case .rename(let folder): "rename-\(folder.id)"
            case .fresh(let folder): "fresh-\(folder.id)"
            }
        }
    }
    /// "Todas as Notas" / "Todas as Teias": every one of that kind in the folder shown.
    @State private var browsing: DocumentKind?
    /// The tile (or folder) a dragged note is over.
    @State private var dropTarget: UUID?
    @State private var naming: NameRequest?
    @State private var name = ""
    @State private var deleting: Folder?
    @State private var query = ""
    @State private var results: [AppModel.SearchResult] = []
    @State private var meaning: [AppModel.SearchResult] = []
    @State private var showSettings = false
    private var searching: Bool { SearchText.query(query) != nil }

    // A scroll view of grouped cards, not a List: in a List the whole grid of tiles is one row,
    // so a drag lifted (and hid) every tile of it and drops never reached a single tile.
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                if searching {
                    SidebarGroup(header: "Resultados",
                                 footer: "Procura no título, no texto, em post-its, transcrições, tabelas e legendas, em todas as pastas. Escrita à mão entra na busca depois de convertida em texto.") {
                        if results.isEmpty && meaning.isEmpty {
                            Text("Nada encontrado para “\(query.trimmingCharacters(in: .whitespaces))”.").foregroundStyle(.secondary)
                                .padding(.horizontal, 16).padding(.vertical, 12).frame(maxWidth: .infinity, alignment: .leading)
                                .accessibilityIdentifier("searchEmpty")
                        }
                        ForEach(results) { result in resultRow(result) }
                    }
                    if !meaning.isEmpty {
                        SidebarGroup(header: "Por significado", footer: "Notas sobre o mesmo assunto, mesmo sem as palavras buscadas. Calculado no próprio aparelho.") {
                            ForEach(meaning) { result in resultRow(result) }
                        }
                    }
                } else if let kind = browsing {
                    // Every note (or Teia) of the folder shown, most recent first.
                    let all = model.recent(kind)
                    SidebarGroup {
                        SidebarRow("Voltar para \(model.folderName(model.currentFolder))", systemImage: "chevron.backward") { browsing = nil }
                            .accessibilityIdentifier("allBack")
                    }
                    if all.isEmpty {
                        Text(kind == .web ? "Nenhuma Teia aqui." : "Nenhuma nota aqui.").foregroundStyle(.secondary).padding(.horizontal, 20)
                    } else {
                        SidebarGroup(header: "\(all.count) \(kind == .web ? (all.count == 1 ? "Teia" : "Teias") : (all.count == 1 ? "nota" : "notas"))", card: false) {
                            documentGrid(all)
                        }
                    }
                } else {
                    SidebarGroup(header: model.currentFolder == nil ? "Notas e Teias" : model.folderName(model.currentFolder)) {
                        if let current = model.folder(model.currentFolder) {
                            SidebarRow("Voltar para \(model.folderName(current.parentID))", systemImage: "chevron.backward") { model.currentFolder = current.parentID }
                                .accessibilityIdentifier("folderBack")
                        }
                        SidebarRow("Nova nota", systemImage: "plus") { Task { await model.createNote(); preferredColumn = .detail } }
                        SidebarRow("Nova nota simples", systemImage: "note.text") { Task { await model.createSimpleNote(); preferredColumn = .detail } }
                            .accessibilityIdentifier("newSimpleNote")
                        SidebarRow("Nova Teia", systemImage: "point.3.connected.trianglepath.dotted") { Task { await model.createWeb(); preferredColumn = .detail } }
                        SidebarRow("Nova pasta", systemImage: "folder.badge.plus") { name = ""; naming = .create }
                            .accessibilityIdentifier("newFolder")
                        ForEach(model.subfolders(of: model.currentFolder)) { folder in folderRow(folder) }
                    }
                    // The nine most recent of each, then the way to all of them.
                    ForEach([DocumentKind.note, .web], id: \.self) { kind in
                        let recent = model.recent(kind, limit: AppModel.recentLimit)
                        if !recent.isEmpty {
                            SidebarGroup(header: kind == .web ? "Teias" : "Notas", card: false) {
                                VStack(spacing: 14) {
                                    documentGrid(recent)
                                    allButton(kind)
                                }
                            }
                        }
                    }
                    SidebarGroup {
                        SidebarRow("Lixeira", systemImage: "trash", detail: model.trashedSummaries.isEmpty ? nil : "\(model.trashedSummaries.count)") { showTrash = true }
                            .accessibilityIdentifier("openTrash")
                        SidebarRow("Ajustes", systemImage: "gearshape") { showSettings = true }
                            .accessibilityIdentifier("openSettings")
                    }
                    HStack(spacing: 8) {
                        ColorSoftwareMark()
                        Text("Color Software").font(.footnote.weight(.bold)).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity).padding(.top, 2).padding(.bottom, 24)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Color Software")
                }
            }
            .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 90)
        }
        .scrollDismissesKeyboard(.immediately)
        .background(Color(uiColor: .systemGroupedBackground))
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
        .navigationTitle(browsing.map { $0 == .web ? "Todas as Teias" : "Todas as Notas" }
                         ?? (model.currentFolder == nil ? "Got It!" : model.folderName(model.currentFolder)))
        .onChange(of: model.currentFolder) { _, _ in browsing = nil }
        // A deleted row (already faded) closes its gap smoothly instead of vanishing.
        .animation(.easeOut(duration: 0.2), value: model.visibleSummaries.map(\.id))
        .animation(.easeOut(duration: 0.2), value: model.currentFolder)
        .animation(.easeOut(duration: 0.2), value: browsing)
        .animation(.spring(duration: 0.25), value: dropTarget)
        .disabled(model.isSaving)
        .alert(namingTitle, isPresented: Binding(get: { naming != nil }, set: { if !$0 { naming = nil } })) {
            // A folder made by dropping shows its generic name as the (lighter) placeholder: typing
            // replaces it, leaving it empty keeps it.
            TextField(namingPlaceholder, text: $name).accessibilityIdentifier("folderName")
            Button(namingAction) {
                let request = naming, chosen = name
                Task {
                    switch request {
                    case .create: await model.createFolder(named: chosen)
                    case .rename(let folder): await model.renameFolder(folder.id, to: chosen)
                    case .fresh(let folder):
                        let typed = chosen.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !typed.isEmpty && typed != folder.name { await model.renameFolder(folder.id, to: typed) }
                    case nil: break
                    }
                }
            }
            // The folder already exists (with its generic name): nothing to cancel.
            if !namingFresh { Button("Cancelar", role: .cancel) { } }
        } message: {
            if case .fresh(let folder) = naming { Text("Sem nome, ela se chama “\(folder.name)”.") }
        }
        .confirmationDialog("Apagar a pasta?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible, presenting: deleting) { folder in
            Button("Apagar “\(folder.name)”", role: .destructive) { Task { await model.deleteFolder(folder.id) } }
        } message: { folder in
            Text("As notas, Teias e pastas de dentro vão para “\(model.folderName(folder.parentID))”. Nenhuma nota é apagada.")
        }
    }

    private var namingTitle: String { if case .rename = naming { "Renomear pasta" } else { "Nova pasta" } }
    private var namingAction: String {
        switch naming {
        case .rename: "Renomear"
        case .fresh: "OK"
        default: "Criar"
        }
    }
    private var namingFresh: Bool { if case .fresh = naming { true } else { false } }
    private var namingPlaceholder: String { if case .fresh(let folder) = naming { folder.name } else { "Nome da pasta" } }

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
            .padding(.horizontal, 16).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(SidebarRowStyle())
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
            HStack(spacing: 12) {
                Image(systemName: "folder").foregroundStyle(Color.accentColor).frame(width: 26)
                Text(folder.name).foregroundStyle(.primary)
                Spacer()
                Text("\(model.count(in: folder.id))").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                Image(systemName: "chevron.forward").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16).frame(minHeight: 46)
            .background(dropTarget == folder.id ? Color.accentColor.opacity(0.15) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(SidebarRowStyle())
        // A note dragged onto a folder goes into it.
        .dropDestination(for: String.self) { items, _ in
            guard let id = draggedID(items) else { return false }
            Task { await model.moveDocument(id, to: folder.id) }
            return true
        } isTargeted: { over in targeting(folder.id, over) }
        .contextMenu {
            Button("Renomear", systemImage: "pencil") { name = folder.name; naming = .rename(folder) }
            moveMenu(excluding: model.descendants(of: folder.id), current: folder.parentID) { target in
                Task { await model.moveFolder(folder.id, to: target) }
            }
            Button("Apagar pasta", systemImage: "trash", role: .destructive) { deleting = folder }
        }
        .accessibilityIdentifier("folder-\(folder.name)")
    }

    /// Notes or Teias three to a row, each a page preview with its title and date; the whole tile
    /// opens it. A long press lifts it: dropped on another tile it makes a folder with both, on a
    /// folder it goes in; held still, it offers moving, a Teia and deleting.
    private func documentGrid(_ items: [DocumentSummary]) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14, alignment: .top), count: 3), spacing: 18) {
            ForEach(items) { summary in documentTile(summary).transition(.opacity) }
        }
        .padding(.vertical, 4)
    }

    /// "Todas as Notas" / "Todas as Teias": the width of the list, the arrow at the right edge,
    /// all of it one button.
    private func allButton(_ kind: DocumentKind) -> some View {
        Button { browsing = kind } label: {
            HStack {
                Text(kind == .web ? "Todas as Teias" : "Todas as Notas").font(.body.weight(.semibold)).foregroundStyle(.primary)
                Spacer(minLength: 8)
                Image(systemName: "chevron.forward").font(.body.weight(.semibold)).foregroundStyle(Color.accentColor)
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.08)))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressedButtonStyle())
        .accessibilityIdentifier(kind == .web ? "allWebs" : "allNotes")
    }

    /// A note or Teia being dragged, from the text it carries (its identifier).
    private func draggedID(_ items: [String]) -> UUID? {
        guard let text = items.first, let id = UUID(uuidString: text), model.activeSummaries.contains(where: { $0.id == id }) else { return nil }
        return id
    }

    private func targeting(_ id: UUID, _ over: Bool) {
        if over { dropTarget = id } else if dropTarget == id { dropTarget = nil }
    }

    private func documentTile(_ summary: DocumentSummary) -> some View {
        let targeted = dropTarget == summary.id
        return Button { Task { await model.open(summary.id); preferredColumn = .detail } } label: {
            VStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10).fill(Color(uiColor: .secondarySystemGroupedBackground))
                    if summary.kind == .web {
                        // Teias have their own picture: post-its tied by threads, in the app's colors.
                        Image("TeiaArt").resizable().scaledToFill()
                    } else if let preview = model.noteMetadata[summary.id]?.preview {
                        Image(uiImage: preview).resizable().scaledToFit().padding(5)
                    } else {
                        Image(systemName: "note.text").font(.system(size: 30)).foregroundStyle(.secondary)
                    }
                    if targeted {
                        RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.opacity(0.18))
                        Image(systemName: "folder.badge.plus").font(.system(size: 28, weight: .semibold)).foregroundStyle(Color.accentColor)
                            .padding(10).background(.regularMaterial, in: Circle())
                    }
                }
                .aspectRatio(0.78, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(targeted || model.document?.id == summary.id ? Color.accentColor : Color.primary.opacity(0.1),
                                                                    lineWidth: targeted || model.document?.id == summary.id ? 2 : 1))
                .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
                .scaleEffect(targeted ? 1.06 : 1)
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
        // Long press and drag: the tile lifts and follows the finger.
        .draggable(summary.id.uuidString) {
            tilePreview(summary)
        }
        .dropDestination(for: String.self) { items, _ in
            guard let dragged = draggedID(items), dragged != summary.id else { return false }
            Task {
                guard let folder = await model.makeFolder(dropping: dragged, onto: summary.id) else { return }
                name = ""; naming = .fresh(folder)
            }
            return true
        } isTargeted: { over in targeting(summary.id, over) }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("document-\(summary.title)")
    }

    /// What follows the finger while a tile is dragged: its page, a little raised.
    private func tilePreview(_ summary: DocumentSummary) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10).fill(Color(uiColor: .secondarySystemGroupedBackground))
            if summary.kind == .web { Image("TeiaArt").resizable().scaledToFill() }
            else if let preview = model.noteMetadata[summary.id]?.preview { Image(uiImage: preview).resizable().scaledToFit().padding(5) }
            else { Image(systemName: "note.text").font(.system(size: 30)).foregroundStyle(.secondary) }
        }
        .frame(width: 96, height: 123)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.25), radius: 10, y: 6)
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

/// Darkens a little while pressed (a plain button in a list shows no highlight of its own).
struct PressedButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.6 : 1).animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// The Color Software mark: four dots, two by two (plum, green, ink and grey), as on
/// colorsoftware.com.br. The ink dot turns white in dark mode, as on the site's dark cover.
struct ColorSoftwareMark: View {
    var dot: CGFloat = 9
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        let colors: [Color] = [Color(red: 0x5a / 255, green: 0x2c / 255, blue: 0x4e / 255),
                               Color(red: 0x0f / 255, green: 0x7d / 255, blue: 0x72 / 255),
                               scheme == .dark ? .white : Color(red: 0x1c / 255, green: 0x1c / 255, blue: 0x1e / 255),
                               scheme == .dark ? Color(red: 0x8a / 255, green: 0x8a / 255, blue: 0x90 / 255) : Color(red: 0xb9 / 255, green: 0xb9 / 255, blue: 0xbe / 255)]
        Grid(horizontalSpacing: dot / 3, verticalSpacing: dot / 3) {
            GridRow { Circle().fill(colors[0]); Circle().fill(colors[1]) }
            GridRow { Circle().fill(colors[2]); Circle().fill(colors[3]) }
        }
        .frame(width: dot * 2 + dot / 3, height: dot * 2 + dot / 3)
        .accessibilityHidden(true)
    }
}

/// A group of the menu, like a section of a grouped list: an optional title, the rows on a rounded
/// card with lines between them (or, with `card: false`, straight on the background), a note below.
struct SidebarGroup<Content: View>: View {
    var header: String? = nil
    var footer: String? = nil
    var card = true
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let header {
                Text(header).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 4)
            }
            if card {
                VStack(spacing: 0) {
                    Group(subviews: content) { rows in
                        ForEach(rows) { row in
                            row
                            if row.id != rows.last?.id { Divider().padding(.leading, 54) }
                        }
                    }
                }
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
                .clipShape(RoundedRectangle(cornerRadius: 14))
            } else {
                content
            }
            if let footer {
                Text(footer).font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 4)
            }
        }
    }
}

/// One row of a group: icon, title and (optionally) a number at the right; the whole row taps.
struct SidebarRow: View {
    let title: String
    let systemImage: String
    var detail: String? = nil
    let action: () -> Void
    init(_ title: String, systemImage: String, detail: String? = nil, action: @escaping () -> Void) {
        self.title = title; self.systemImage = systemImage; self.detail = detail; self.action = action
    }
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage).foregroundStyle(Color.accentColor).frame(width: 26)
                Text(title).foregroundStyle(Color.accentColor)
                Spacer()
                if let detail { Text(detail).foregroundStyle(.secondary) }
            }
            .padding(.horizontal, 16).frame(minHeight: 46)
            .contentShape(Rectangle())
        }
        .buttonStyle(SidebarRowStyle())
    }
}

/// A row turns grey while pressed, as rows of a list do.
struct SidebarRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.background(configuration.isPressed ? Color(uiColor: .systemFill) : Color.clear)
    }
}
