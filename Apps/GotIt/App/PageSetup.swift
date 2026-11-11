import SwiftUI
import UniformTypeIdentifiers
import GotItDomain

/// Header, footer and page numbers of a note (the same on every page).
struct PageSetupView: View {
    enum Focus: Hashable, Identifiable { case bands, numbers; var id: Self { self } }
    @Bindable var model: AppModel
    @State var settings: CanvasSettings
    let focus: Focus
    @Environment(\.dismiss) private var dismiss
    @State private var assets: [Asset] = []
    @State private var picking: Band?
    private enum Band { case header, footer }

    var body: some View {
        NavigationStack {
            ScrollViewReader { reader in
                Form {
                    bandSection("Cabeçalho", band: $settings.header, which: .header)
                    bandSection("Rodapé", band: $settings.footer, which: .footer)
                    Section {
                        Toggle("Numerar páginas", isOn: Binding(get: { settings.pageNumbers != nil },
                                                                set: { settings.pageNumbers = $0 ? (settings.pageNumbers ?? PageNumbering()) : nil }))
                            .accessibilityIdentifier("numberPagesToggle")
                        if settings.pageNumbers != nil {
                            Picker("Onde", selection: numbers(\.place)) { Text("Rodapé").tag(PageNumbering.Place.footer); Text("Cabeçalho").tag(PageNumbering.Place.header) }
                            Picker("Alinhamento", selection: numbers(\.alignment)) { alignmentOptions }
                                .pickerStyle(.segmented)
                            Picker("Formato", selection: numbers(\.format)) {
                                Text("1").tag(PageNumbering.Format.number)
                                Text("Página 1 de N").tag(PageNumbering.Format.pageOfTotal)
                                Text("– 1 –").tag(PageNumbering.Format.dashes)
                            }
                            Stepper("Começar em \(settings.pageNumbers?.startAt ?? 1)", value: numbers(\.startAt), in: 0...9999)
                            Toggle("Sem número na primeira página", isOn: numbers(\.skipFirstPage))
                        }
                    } header: { Text("Números de página") }
                    .id(Focus.numbers)
                }
                .onAppear { if focus == .numbers { reader.scrollTo(Focus.numbers, anchor: .top) } }
            }
            .navigationTitle("Cabeçalho e rodapé")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Aplicar") { model.applyPageLayout(settings, assets: assets); dismiss() }.accessibilityIdentifier("applyPageSetup")
                }
            }
            .fileImporter(isPresented: Binding(get: { picking != nil }, set: { if !$0 { picking = nil } }), allowedContentTypes: [.image, .pdf]) { result in
                guard let which = picking else { return }
                picking = nil
                do {
                    let asset = try model.bandAsset(from: result.get())
                    assets.append(asset)
                    switch which {
                    case .header: settings.header?.image = asset.hash
                    case .footer: settings.footer?.image = asset.hash
                    }
                } catch { model.error = (error as? DocumentError).flatMap { if case .invalid(let text) = $0 { text } else { nil } } ?? error.localizedDescription }
            }
        }
    }

    @ViewBuilder private var alignmentOptions: some View {
        Image(systemName: "text.alignleft").tag(BandAlignment.leading)
        Image(systemName: "text.aligncenter").tag(BandAlignment.center)
        Image(systemName: "text.alignright").tag(BandAlignment.trailing)
    }

    private func numbers<T>(_ path: WritableKeyPath<PageNumbering, T>) -> Binding<T> {
        Binding(get: { (settings.pageNumbers ?? PageNumbering())[keyPath: path] },
                set: { var n = settings.pageNumbers ?? PageNumbering(); n[keyPath: path] = $0; settings.pageNumbers = n })
    }

    private func bandSection(_ title: String, band: Binding<PageBand?>, which: Band) -> some View {
        Section {
            Toggle("Usar \(title.lowercased())", isOn: Binding(get: { band.wrappedValue != nil }, set: { band.wrappedValue = $0 ? (band.wrappedValue ?? PageBand()) : nil }))
                .accessibilityIdentifier(which == .header ? "headerToggle" : "footerToggle")
            if let current = band.wrappedValue {
                VStack(alignment: .leading) {
                    Text("Altura: \((current.height * 2.54 / 72).formatted(.number.precision(.fractionLength(1)))) cm")
                    Slider(value: Binding(get: { current.height }, set: { band.wrappedValue?.height = $0 }),
                           in: PageMargins.centimeters(1)...PageMargins.centimeters(8), step: PageMargins.centimeters(0.1))
                }
                TextField("Texto (opcional)", text: Binding(get: { current.text }, set: { band.wrappedValue?.text = $0 }))
                Picker("Alinhamento", selection: Binding(get: { current.alignment }, set: { band.wrappedValue?.alignment = $0 })) { alignmentOptions }
                    .pickerStyle(.segmented)
                if let hash = current.image, let image = model.image(hash) {
                    Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 80).frame(maxWidth: .infinity)
                    Button("Trocar arquivo…") { picking = which }
                    Button("Remover imagem", role: .destructive) { band.wrappedValue?.image = nil }
                } else {
                    Button("Carregar imagem ou PDF…") { picking = which }
                }
            }
        } header: { Text(title) } footer: {
            if which == .footer { Text("O texto da nota fica fora do cabeçalho e do rodapé. Objetos podem entrar neles: uma linha tracejada mostra o limite enquanto você os move.") }
        }
    }
}
