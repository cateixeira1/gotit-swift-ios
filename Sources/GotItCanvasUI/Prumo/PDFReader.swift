#if canImport(UIKit)
import SwiftUI
import PDFKit

/// Embedded Prumo reader: all pages, thumbnails, search, native selection and highlights.
public struct PDFReader: View {
    private let url: URL
    private let onSave: (Data) throws -> Void
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = ReaderModel()
    @StateObject private var history = ReaderHistory()
    @State private var query = ""
    @State private var thumbnails = true
    @State private var dirty = false
    @State private var error: String?

    public init(url: URL, onSave: @escaping (Data) throws -> Void) {
        self.url = url; self.onSave = onSave
    }
    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack {
                    TextField("Buscar no PDF", text: $query).textFieldStyle(.roundedBorder).onSubmit { model.search(query) }
                    Button("Buscar") { model.search(query) }
                    Button { model.previous() } label: { Image(systemName: "chevron.up") }.disabled(model.results.isEmpty)
                    Button { model.next() } label: { Image(systemName: "chevron.down") }.disabled(model.results.isEmpty)
                }.padding(8)
                if model.searched { Text("\(model.results.isEmpty ? 0 : model.resultIndex + 1) / \(model.results.count) resultados").font(.caption) }
                PDFKitView(url: url, model: model, showThumbnails: thumbnails)
                HStack {
                    Button { thumbnails.toggle() } label: { Image(systemName: "sidebar.left") }.accessibilityLabel("Miniaturas")
                    Button { model.go(toPage: model.currentPage - 1) } label: { Image(systemName: "chevron.left") }.disabled(model.currentPage <= 1)
                    Text("\(model.currentPage) / \(model.pageCount)").monospacedDigit().accessibilityIdentifier("pdfPageNumber")
                    Button { model.go(toPage: model.currentPage + 1) } label: { Image(systemName: "chevron.right") }.disabled(model.currentPage >= model.pageCount)
                    Spacer()
                    Menu {
                        ForEach(HighlightColor.allCases) { color in Button(color.label) { model.highlightSelection(color) } }
                        Button("Remover destaque") { model.unmarkSelection() }
                    } label: { Image(systemName: "highlighter") }.disabled(!model.hasSelection)
                    Button { undo() } label: { Image(systemName: "arrow.uturn.backward") }.disabled(!history.canUndo)
                    Button { redo() } label: { Image(systemName: "arrow.uturn.forward") }.disabled(!history.canRedo)
                }.padding()
            }.navigationTitle("PDF")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("Concluir") { save() } }
                }
                .onAppear { model.onEdit = { label, change in history.record(label, change); dirty = true } }
                .interactiveDismissDisabled(dirty)
                .alert("Não foi possível salvar", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                    Button("OK") { error = nil }
                } message: { Text(error ?? "") }
        }
    }
    private func undo() {
        guard let doc = model.pdfView?.document, let step = history.popUndo() else { return }
        ReaderHistory.apply(step.change, forward: false, in: doc); history.pushRedo(step); dirty = true
    }
    private func redo() {
        guard let doc = model.pdfView?.document, let step = history.popRedo() else { return }
        ReaderHistory.apply(step.change, forward: true, in: doc); history.pushUndo(step); dirty = true
    }
    private func save() {
        do {
            if dirty {
                guard let bytes = model.pdfView?.document?.dataRepresentation() else { throw CocoaError(.fileWriteUnknown) }
                try onSave(bytes)
            }
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
#endif
