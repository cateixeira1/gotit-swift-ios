import SwiftUI
import GotItDomain
import GotItCanvasUI

/// Paper of the note or of one page: plain, notebook (yellow, ruled, brown top), squares or a
/// white and light grey checkerboard; squares sized in millimetres and always square.
struct PaperPicker: View {
    @Bindable var model: AppModel
    let pageID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var kind: PaperStyle.Kind
    @State private var millimetres: Double
    @State private var scope = AppModel.PaperScope.note

    init(model: AppModel, pageID: UUID, current: PaperStyle?) {
        self.model = model; self.pageID = pageID
        _kind = State(initialValue: current?.kind ?? .grid)
        _millimetres = State(initialValue: ((current?.size ?? PageMargins.centimeters(0.5)) * 25.4 / 72).rounded())
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Papel") {
                    Picker("Estilo", selection: $kind) {
                        Text("Liso").tag(PaperStyle.Kind.plain)
                        Text("Caderno").tag(PaperStyle.Kind.notebook)
                        Text("Quadriculado").tag(PaperStyle.Kind.grid)
                        Text("Xadrez").tag(PaperStyle.Kind.checker)
                    }.pickerStyle(.segmented).accessibilityIdentifier("paperKind")
                    if kind == .grid || kind == .checker {
                        Stepper("Quadrados de \(Int(millimetres)) mm", value: $millimetres, in: 3...20)
                    }
                    Preview(style: style).frame(height: 120).clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.secondary.opacity(0.3)))
                }
                Section("Aplicar em") {
                    Picker("Aplicar em", selection: $scope) {
                        ForEach(AppModel.PaperScope.allCases) { Text($0.title).tag($0) }
                    }.pickerStyle(.inline).labelsHidden()
                }
            }
            .navigationTitle("Papel").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Aplicar") { model.setPaper(style, scope: scope, pageID: pageID); dismiss() }.accessibilityIdentifier("applyPaper")
                }
            }
        }
    }

    private var style: PaperStyle {
        PaperStyle(kind: kind, size: kind == .notebook ? PaperStyle.notebookLine : PageMargins.centimeters(millimetres / 10))
    }

    /// A strip of the paper as it will look (scaled like the page on screen).
    private struct Preview: UIViewRepresentable {
        let style: PaperStyle
        func makeUIView(context: Context) -> PreviewView { PreviewView() }
        func updateUIView(_ view: PreviewView, context: Context) { view.style = style }
        final class PreviewView: UIView {
            var style = PaperStyle(kind: .plain) { didSet { setNeedsDisplay() } }
            override init(frame: CGRect) { super.init(frame: frame); backgroundColor = .white; contentMode = .redraw }
            required init?(coder: NSCoder) { fatalError() }
            override func draw(_ rect: CGRect) {
                var settings = CanvasSettings(size: CanvasSize(width: Double(bounds.width), height: Double(bounds.height) * 2))
                settings.margins = PageMargins(top: 0, bottom: 0, left: 40, right: 0)
                PaperPreviewDrawing.draw(style, settings: settings)
            }
        }
    }
}
