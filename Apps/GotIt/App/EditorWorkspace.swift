import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import GotItDomain
import GotItCanvasUI

struct EditorWorkspace: View {
    @Bindable var model: AppModel
    let document: CanvasDocument
    @Environment(\.scenePhase) private var scenePhase
    @State private var session = EditorSession()
    @State private var tool = CanvasTool.select
    @State private var inkColor = Color.primary
    @State private var inkWidth = 3.0
    @State private var vectorEraser = false
    @State private var showPages = false
    @State private var showTools = false
    @State private var showPhotos = false
    @State private var showPDF = false
    @State private var showStickers = false
    @State private var pageScrollRequest = 0
    @State private var reader: PDFTarget?
    private struct PDFTarget: Identifiable { var id: UUID; var documentID: UUID; var url: URL }
    @State private var photo: PhotosPickerItem?
    @State private var importTarget: ImportTarget?

    private struct ImportTarget {
        var documentID: UUID
        var pageID: UUID
        var sticker: Bool
    }
    private var pageID: UUID { model.activePageID ?? document.id }

    var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width >= 700
            VStack(spacing: 0) {
                formattingBar
                Divider()
                HStack(spacing: 0) {
                    if wide { pagesPanel.frame(width: 142); Divider() }
                    canvas
                    if wide { Divider(); toolsPanel.frame(width: 106) }
                }
                if !wide { Divider(); compactBar }
            }
            .background(Color(uiColor: .systemBackground))
        }
        // The page view keeps the caret above the keyboard itself (scroll insets), so the layout does
        // not shrink and the bottom bar stays put behind the keyboard.
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .sheet(isPresented: $showPages) {
            NavigationStack { pagesPanel.navigationTitle("Páginas").toolbar { Button("Concluir") { showPages = false } } }
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showTools) {
            NavigationStack { toolsPanel.navigationTitle("Ferramentas").toolbar { Button("Concluir") { showTools = false } } }
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showStickers) { stickerPicker.presentationDetents([.medium, .large]) }
        .sheet(item: $reader) { target in
            PDFReader(url: target.url) { data in try model.savePDF(data, blockID: target.id, documentID: target.documentID) }
        }
        .photosPicker(isPresented: $showPhotos, selection: $photo, matching: .images)
        .onChange(of: photo) { _, item in
            if let item, let target = importTarget {
                Task { await model.importImage(item, sticker: target.sticker, pageID: target.pageID, documentID: target.documentID) }
                photo = nil
            }
        }
        .fileImporter(isPresented: $showPDF, allowedContentTypes: [.pdf]) { result in
            guard let target = importTarget else { return }
            switch result {
            case .success(let url): model.importPDF(url, pageID: target.pageID, documentID: target.documentID)
            case .failure(let error): model.error = error.localizedDescription
            }
        }
        .onChange(of: document.id) { _, _ in tool = .select; session.hasTextSelection = false }
        .onChange(of: scenePhase) { _, phase in if phase != .active { session.perform(.finish) } }
    }

    private var canvas: some View {
        PagedCanvasEditor(pages: document.pages.map { pageEditor($0.id) }, tool: tool, session: session,
                          focusPageID: pageID, scrollRequest: pageScrollRequest,
                          onStoryEdit: { story, range, edit in model.editStory(story, range: range, edit: edit) },
                          onVisiblePage: { model.selectedPageID = $0 })
            .id(document.id)
            .accessibilityIdentifier("pageEditor")
            .overlay(alignment: .bottomTrailing) { floatingPen }
    }

    /// One tap to draw, one tap to go back to the cursor; no need to open the tools panel.
    private var floatingPen: some View {
        Button {
            session.perform(.finish)
            tool = tool.isDrawing ? .select : .pen
        } label: {
            Image(systemName: tool.isDrawing ? "pencil.tip.crop.circle.fill" : "pencil.tip")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(tool.isDrawing ? Color.white : Color.accentColor)
                .frame(width: 58, height: 58)
                .background(tool.isDrawing ? Color.accentColor : Color(uiColor: .systemBackground), in: Circle())
                .shadow(color: .black.opacity(0.22), radius: 6, y: 3)
        }
        .padding(18)
        .accessibilityLabel(tool.isDrawing ? "Parar de desenhar" : "Desenhar com a caneta")
        .accessibilityIdentifier("floatingPen")
    }

    private func pageEditor(_ targetPage: UUID) -> CanvasEditor {
        // Capture identifiers, so delayed imports/drawing callbacks never land on another page.
        let targetDocument = document.id
        let page = (try? document.pageDocument(targetPage)) ?? document
        return CanvasEditor(document: page, tool: tool, session: session,
            inkColor: UIColor(inkColor).resolvedColor(with: UITraitCollection(userInterfaceStyle: .light)),
            inkWidth: inkWidth, vectorEraser: vectorEraser,
            drawingData: model.assetData,
            onDrawing: { save, commands in model.saveDrawing(save, extra: commands, pageID: targetPage, documentID: targetDocument) },
            image: model.image, note: { model.noteMetadata[$0] },
            onTextCommands: { block, group, selection in model.editText(block, group: group, selection: selection) },
            onBackspaceAtStart: { id, group in model.backspaceAcrossFragments(id, group: group) },
            onCommands: { model.enqueue($0, pageID: targetPage, documentID: targetDocument) },
            onOpenPDF: { id in
                if let block = document.blocks.first(where: { $0.id == id }), let hash = block.content.assetHash, let url = model.assetURL(hash) {
                    reader = .init(id: id, documentID: targetDocument, url: url)
                }
            },
            onOpenNote: { id in Task { await model.open(id, returningTo: document.kind == .web ? document.id : nil) } },
            onError: { model.error = String(describing: $0) })
    }

    private var formattingBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 16) {
                HStack(spacing: 16) {
                    Menu("Fonte") {
                        ForEach(["Sistema", "Helvetica", "Times New Roman", "Menlo"], id: \.self) { name in
                            Button(name) { session.perform(.font(name)) }
                        }
                    }.font(.subheadline)
                    Menu { ForEach([10, 12, 14, 16, 18, 20, 24, 28, 36, 48, 72], id: \.self) { size in
                        Button("\(size) pt") { session.perform(.fontSize(CGFloat(size))) }
                    } } label: { Image(systemName: "textformat.size") }.accessibilityLabel("Tamanho da fonte")
                    separator
                    formatButton("Negrito", "bold", .bold)
                    formatButton("Itálico", "italic", .italic)
                    formatButton("Sublinhado", "underline", .underline)
                    Menu {
                        Button("Esquerda") { session.perform(.alignment(.left)) }
                        Button("Centro") { session.perform(.alignment(.center)) }
                        Button("Direita") { session.perform(.alignment(.right)) }
                        Button("Justificado") { session.perform(.alignment(.justified)) }
                    } label: { Image(systemName: "text.alignleft") }.accessibilityLabel("Alinhamento")
                    Menu {
                        Button("Com marcadores") { session.perform(.bulletList) }
                        Button("Numerada") { session.perform(.numberedList) }
                        Button("Remover lista") { session.perform(.removeList) }
                    } label: { Image(systemName: "list.bullet") }.accessibilityLabel("Listas")
                    Menu {
                        Button("Tachado") { session.perform(.strike) }
                        Button("Aumentar recuo") { session.perform(.indent(18)) }
                        Button("Diminuir recuo") { session.perform(.indent(-18)) }
                        Menu("Espaço entre linhas") {
                            ForEach([0, 2, 4, 8, 12], id: \.self) { spacing in Button("\(spacing) pt") { session.perform(.lineSpacing(CGFloat(spacing))) } }
                        }
                        Menu("Cor do texto") {
                            Button("Preto") { session.perform(.foreground(.black)) }
                            Button("Azul") { session.perform(.foreground(.systemBlue)) }
                            Button("Vermelho") { session.perform(.foreground(.systemRed)) }
                            Button("Verde") { session.perform(.foreground(.systemGreen)) }
                        }
                        Button("Inserir link") { session.perform(.link) }
                        Button("Localizar e substituir") { session.perform(.find) }
                    } label: { Image(systemName: "textformat") }.accessibilityLabel("Mais opções de texto")
                }.disabled(!session.hasTextSelection || tool.isDrawing)
                separator
                Menu {
                    Button("Ajustar à largura") { session.perform(.fitPage) }
                    Button("Ampliar") { session.perform(.zoom(1.25)) }
                    Button("Reduzir") { session.perform(.zoom(0.8)) }
                } label: { Image(systemName: "magnifyingglass") }.accessibilityLabel("Zoom")
                Button { session.perform(.finish) } label: { Image(systemName: "keyboard.chevron.compact.down") }.accessibilityLabel("Fechar teclado")
            }.font(.system(size: 16)).padding(.horizontal, 18).frame(height: 44)
        }.background(.bar)
    }
    private var separator: some View { Divider().frame(height: 20) }
    private func formatButton(_ title: String, _ symbol: String, _ action: TextEditingAction) -> some View {
        Button { session.perform(action) } label: { Image(systemName: symbol).frame(minWidth: 28, minHeight: 40) }
            .accessibilityLabel(title)
    }

    private var pagesPanel: some View {
        ScrollView {
            LazyVStack(spacing: 20) {
                HStack {
                    Text("Páginas").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Button { session.perform(.finish); model.addPage(); pageScrollRequest += 1 } label: { Image(systemName: "plus") }
                        .accessibilityLabel("Adicionar página").accessibilityIdentifier("addPage")
                        .frame(minWidth: 32, minHeight: 36)
                }
                ForEach(Array(document.pages.enumerated()), id: \.element.id) { index, item in
                    if let previewPage = try? document.pageDocument(item.id) {
                        Button {
                            session.perform(.finish)
                            model.selectedPageID = item.id
                            pageScrollRequest += 1
                            showPages = false
                        } label: {
                            VStack(spacing: 7) {
                                PageThumbnail(model: model, document: previewPage)
                                    .frame(width: 100, height: 138)
                                    .background(.white, in: RoundedRectangle(cornerRadius: 4))
                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                                    .shadow(color: .black.opacity(0.09), radius: 3, y: 2)
                                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(pageID == item.id ? Color.accentColor : Color.secondary.opacity(0.2), lineWidth: pageID == item.id ? 3 : 1))
                                Text("\(index + 1)").font(.caption.monospacedDigit()).foregroundStyle(pageID == item.id ? Color.accentColor : .secondary)
                            }
                        }.buttonStyle(.plain).accessibilityLabel(item.title)
                            .accessibilityIdentifier("page-\(index + 1)")
                            .accessibilityAddTraits(pageID == item.id ? .isSelected : [])
                    }
                }
            }.padding(14)
        }.background(Color(uiColor: .secondarySystemBackground))
    }

    private static let stickerEmoji = [
        "⭐️", "✅", "❗️", "❓", "⚠️", "📌", "📎", "💡", "🔥", "🎯", "🚩", "🛑",
        "❤️", "👍", "👏", "🎉", "😀", "😂", "😍", "🤔", "🙏", "💪", "👀", "✨",
        "⏰", "📝", "📚", "⚖️", "🏥", "💊", "🩺", "📞", "✉️", "💰", "📈",
        "🏠", "🚗", "✈️", "☕️", "🍰", "🐱", "☀️", "🌧️", "🔒", "🔑", "➡️", "⬇️",
    ]

    private var stickerPicker: some View {
        NavigationStack {
            ScrollView {
                HStack(spacing: 18) {
                    Button {
                        showStickers = false; model.insertStickyNote(pageID: pageID, documentID: document.id)
                    } label: {
                        VStack(spacing: 6) {
                            ZStack(alignment: .topLeading) {
                                Rectangle().fill(Color(red: 1, green: 0.95, blue: 0.48))
                                    .frame(width: 74, height: 74).shadow(color: .black.opacity(0.22), radius: 3, y: 3)
                                Text("Escreva…").font(.custom("Noteworthy-Bold", size: 12)).foregroundStyle(.black.opacity(0.6)).padding(8).padding(.top, 6)
                            }
                            Text("Post-it").font(.caption)
                        }
                    }.buttonStyle(.plain).accessibilityLabel("Post-it").accessibilityIdentifier("stickyNoteSticker")
                    Button {
                        showStickers = false; model.insertCalendar(pageID: pageID, documentID: document.id)
                    } label: {
                        VStack(spacing: 6) {
                            VStack(spacing: 0) {
                                Text(Date().formatted(.dateTime.month(.abbreviated).locale(Locale(identifier: "pt_BR"))).replacingOccurrences(of: ".", with: "").uppercased())
                                    .font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                                    .frame(maxWidth: .infinity, minHeight: 22).background(Color(red: 0.9, green: 0.27, blue: 0.23))
                                Text(Date().formatted(.dateTime.day()))
                                    .font(.system(size: 32, weight: .semibold)).foregroundStyle(.black.opacity(0.85))
                                    .frame(maxWidth: .infinity, maxHeight: .infinity).background(.white)
                            }
                            .frame(width: 66, height: 74).clipShape(RoundedRectangle(cornerRadius: 9))
                            .overlay(RoundedRectangle(cornerRadius: 9).stroke(.black.opacity(0.12)))
                            .shadow(color: .black.opacity(0.2), radius: 3, y: 3)
                            Text("Calendário").font(.caption)
                        }
                    }.buttonStyle(.plain).accessibilityLabel("Calendário").accessibilityIdentifier("calendarSticker")
                }.padding(.top, 12)
                Button { showStickers = false; beginImport(sticker: true, pdf: false) } label: {
                    Label("Usar uma imagem da galeria", systemImage: "photo.on.rectangle").frame(maxWidth: .infinity)
                }.buttonStyle(.bordered).padding(.horizontal).padding(.top, 8)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 56))], spacing: 12) {
                    ForEach(Self.stickerEmoji, id: \.self) { emoji in
                        Button {
                            showStickers = false
                            if let png = Self.stickerPNG(emoji) { model.insertSticker(png: png, pageID: pageID, documentID: document.id) }
                        } label: { Text(emoji).font(.system(size: 40)).frame(width: 56, height: 56) }
                        .accessibilityLabel("Sticker \(emoji)")
                    }
                }.padding()
            }
            .navigationTitle("Stickers")
            .toolbar { Button("Fechar") { showStickers = false } }
        }
    }

    /// Emoji rendered once to a transparent PNG, stored like any image (hash-addressed).
    private static func stickerPNG(_ emoji: String) -> Data? {
        let format = UIGraphicsImageRendererFormat(); format.scale = 2; format.opaque = false
        let size = CGSize(width: 240, height: 240)
        let centered = NSMutableParagraphStyle(); centered.alignment = .center
        let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            (emoji as NSString).draw(in: CGRect(x: 0, y: 12, width: size.width, height: size.height - 12),
                                     withAttributes: [.font: UIFont.systemFont(ofSize: 180), .paragraphStyle: centered])
        }
        return image.pngData()
    }

    private var toolsPanel: some View {
        ScrollView {
            VStack(spacing: 16) {
                toolButton(.select)
                Divider()
                Text("DESTACAR").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                HStack(spacing: 7) {
                    highlight("Amarelo", .systemYellow)
                    highlight("Verde", .systemGreen)
                    highlight("Rosa", .systemPink)
                }.disabled(!session.hasTextSelection || tool.isDrawing)
                Button("Limpar destaque") { session.perform(.highlight(nil)) }
                    .font(.system(size: 10)).disabled(!session.hasTextSelection || tool.isDrawing)
                Divider()
                Text("INSERIR").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                paletteButton("Texto", "text.badge.plus") { showTools = false; session.perform(.insertText) }
                paletteButton("Tabela", "tablecells") { showTools = false; session.perform(.insertTable) }
                paletteButton("Imagem", "photo") { beginImport(sticker: false, pdf: false) }
                paletteButton("PDF", "doc.richtext") { beginImport(sticker: false, pdf: true) }
                paletteButton("Sticker", "face.smiling") { session.perform(.finish); showTools = false; showStickers = true }
                Divider()
                Text("DESENHAR").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                ForEach(CanvasTool.allCases.filter { $0 != .select }) { item in toolButton(item) }
                Divider()
                ColorPicker("Cor", selection: $inkColor, supportsOpacity: false).font(.caption)
                VStack(spacing: 6) {
                    Text("Traço: \(inkWidth.formatted(.number.precision(.fractionLength(1)))) pt").font(.system(size: 10))
                    Slider(value: $inkWidth, in: 1...20, step: 0.5).accessibilityLabel("Largura do traçado")
                }.disabled(tool == .eraser)
                if tool == .eraser {
                    Toggle("Traço inteiro", isOn: $vectorEraser).font(.caption)
                }
                Text("Dois dedos para mover ao desenhar").font(.system(size: 10)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }.padding(.horizontal, 10).padding(.vertical, 14)
        }.background(.bar)
    }
    private func toolButton(_ item: CanvasTool) -> some View {
        paletteButton(item.title, item.symbol, selected: tool == item) {
            session.perform(.finish); tool = item
            if item.isDrawing { showTools = false }
        }.accessibilityIdentifier("tool-\(item.rawValue)")
    }
    private func paletteButton(_ title: String, _ symbol: String, selected: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 23, weight: .regular))
                Text(title).font(.system(size: 10, weight: .medium))
            }.frame(maxWidth: .infinity, minHeight: 48)
                .foregroundStyle(selected ? Color.accentColor : Color.primary)
                .background(selected ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 10))
        }.buttonStyle(.plain).accessibilityLabel(title).accessibilityAddTraits(selected ? .isSelected : [])
    }
    private func highlight(_ title: String, _ color: UIColor) -> some View {
        Button { session.perform(.highlight(color.withAlphaComponent(0.35))) } label: {
            Circle().fill(Color(uiColor: color)).frame(width: 21, height: 21)
                .overlay(Circle().stroke(.primary.opacity(0.12), lineWidth: 1))
        }.accessibilityLabel("Destacar em \(title)")
    }
    private func beginImport(sticker: Bool, pdf: Bool) {
        session.perform(.finish); showTools = false
        importTarget = .init(documentID: document.id, pageID: pageID, sticker: sticker)
        // A single sheet closes before the system picker is presented.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            if pdf { showPDF = true } else { showPhotos = true }
        }
    }
    private var compactBar: some View {
        HStack {
            Button { showPages = true } label: { Label("Páginas", systemImage: "rectangle.stack") }.accessibilityIdentifier("showPages")
            Spacer()
            Button { session.perform(.finish); tool = tool.isDrawing ? .select : .pen } label: { Image(systemName: tool.symbol).font(.title3) }.accessibilityLabel(tool.isDrawing ? "Voltar à seleção" : "Desenhar")
            Spacer()
            Button { showTools = true } label: { Label("Ferramentas", systemImage: "slider.horizontal.3") }.accessibilityIdentifier("showTools")
        }.font(.subheadline).padding(.horizontal, 16).frame(height: 50).background(.bar)
    }
}

private struct PageThumbnail: View {
    let model: AppModel
    let document: CanvasDocument
    @State private var preview: UIImage?
    var body: some View {
        Group {
            if let preview { Image(uiImage: preview).resizable().scaledToFit() }
            else { Color.white }
        }.task(id: document.revision) {
            do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
            preview = model.pagePreview(document)
        }
    }
}
