import SwiftUI
import GotItDomain
import GotItPersistence

/// Choosing the note a text links to: every note and Teia (not in the Lixeira), found by title.
struct NotePicker: View {
    @Bindable var model: AppModel
    let excluding: UUID
    let onPick: (DocumentSummary) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var choices: [DocumentSummary] {
        let all = model.activeSummaries.filter { $0.id != excluding }
        guard SearchText.query(query) != nil else { return all }
        return all.filter { $0.title.range(of: query.trimmingCharacters(in: .whitespaces), options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }

    var body: some View {
        NavigationStack {
            List(choices) { summary in
                Button { onPick(summary); dismiss() } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Label(summary.title, systemImage: summary.kind == .web ? "point.3.connected.trianglepath.dotted" : "note.text")
                        if let folder = summary.folderID { Text(model.folderName(folder)).font(.caption).foregroundStyle(.secondary) }
                    }
                }.accessibilityIdentifier("pick-\(summary.title)")
            }
            .overlay { if choices.isEmpty { ContentUnavailableView.search(text: query) } }
            .searchable(text: $query, prompt: "Título da nota")
            .navigationTitle("Ligar a uma nota").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } } }
        }
    }
}

/// The notes and Teias that point to a note (links in their text, Teia cards).
struct BacklinksView: View {
    @Bindable var model: AppModel
    let documentID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var sources: [DocumentSummary]?

    var body: some View {
        NavigationStack {
            List {
                if let sources {
                    if sources.isEmpty {
                        ContentUnavailableView("Nenhuma nota cita esta", systemImage: "link",
                                               description: Text("Use “Ligar a outra nota…” no menu do texto de outra nota, ou ponha esta nota numa Teia."))
                    }
                    ForEach(sources) { summary in
                        Button {
                            dismiss()
                            Task { await model.open(summary.id, returningTo: documentID) }
                        } label: {
                            Label(summary.title, systemImage: summary.kind == .web ? "point.3.connected.trianglepath.dotted" : "note.text")
                        }.accessibilityIdentifier("backlink-\(summary.title)")
                    }
                } else { ProgressView() }
            }
            .navigationTitle("Citada em").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("OK") { dismiss() } } }
            .task { sources = await model.backlinks(to: documentID) }
        }
    }
}
