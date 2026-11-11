import SwiftUI
import PhotosUI
import AVKit
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
    /// What the file picker is choosing: a PDF (as a block, or as pages to write on) or an audio file.
    @State private var fileKind = FileKind.pdf
    private enum FileKind { case pdf, pdfPages, audio }
    @State private var showRecorder = false
    /// Audio whose transcription is being placed (asks where the text goes).
    @State private var transcribing: UUID?
    @State private var pickingVideo = false
    @State private var playing: PlayingVideo?
    private struct PlayingVideo: Identifiable { let id: UUID; let player: AVPlayer }
    @State private var showStickers = false
    @State private var pageScrollRequest = 0
    @State private var pageSetup: PageSetupView.Focus?
    @State private var showPaper = false
    @State private var afterTools: (() -> Void)?
    @AppStorage("handwritingToText") private var handwritingToText = false
    @AppStorage("handwritingFont") private var handwritingFont = HandwritingFonts.defaultFont
    @State private var importingFont = false
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
                    if wide { pagesPanel(sheet: false).frame(width: 142); Divider() }
                    canvas
                    if wide { Divider(); toolsPanel(sheet: false).frame(width: 136) }
                }
                if !wide { Divider(); compactBar }
            }
            .background(Color(uiColor: .systemBackground))
        }
        // The page view keeps the caret above the keyboard itself (scroll insets), so the layout does
        // not shrink and the bottom bar stays put behind the keyboard.
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .sheet(isPresented: $showPages) {
            NavigationStack { pagesPanel(sheet: true).navigationTitle("Páginas").navigationBarTitleDisplayMode(.inline).toolbar { Button("Concluir") { showPages = false } } }
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showTools, onDismiss: {
            // What a tool asked to open, once the tools sheet is really gone (two sheets at once:
            // the second is dropped, and a fixed delay was not always enough on iOS 26).
            let next = afterTools; afterTools = nil; next?()
        }) {
            NavigationStack { toolsPanel(sheet: true).navigationTitle("Ferramentas").navigationBarTitleDisplayMode(.inline).toolbar { Button("Concluir") { showTools = false } } }
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showStickers) { stickerPicker.presentationDetents([.medium, .large]) }
        .sheet(item: $pageSetup) { focus in PageSetupView(model: model, settings: document.canvas, focus: focus) }
        .onAppear { session.handwritingToText = handwritingToText; session.handwritingFont = handwritingFont }
        .onChange(of: handwritingToText) { _, on in session.handwritingToText = on }
        .onChange(of: handwritingFont) { _, name in session.handwritingFont = name }
        .fileImporter(isPresented: $importingFont, allowedContentTypes: [.font], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls):
                if let first = model.importFonts(urls).first { handwritingFont = first }
            case .failure(let error): model.error = error.localizedDescription
            }
        }
        .sheet(isPresented: $showPaper) {
            PaperPicker(model: model, pageID: pageID,
                        current: document.pages.first { $0.id == pageID }?.paper?.style ?? document.canvas.paper)
        }
        .sheet(item: $reader) { target in
            PDFReader(url: target.url) { data in try model.savePDF(data, blockID: target.id, documentID: target.documentID) }
        }
        .photosPicker(isPresented: $showPhotos, selection: $photo, matching: pickingVideo ? .videos : .images)
        .onChange(of: photo) { _, item in
            if let item, let target = importTarget {
                if pickingVideo {
                    Task {
                        do {
                            guard let movie = try await item.loadTransferable(type: PickedMovie.self) else { return }
                            await model.insertVideo(from: movie.url, pageID: target.pageID, documentID: target.documentID)
                            try? FileManager.default.removeItem(at: movie.url)
                        } catch { model.error = "Não foi possível abrir o vídeo: \(error.localizedDescription)" }
                    }
                } else {
                    Task { await model.importImage(item, sticker: target.sticker, pageID: target.pageID, documentID: target.documentID) }
                }
                photo = nil
            }
        }
        .fullScreenCover(item: $playing) { video in
            VideoPlayer(player: video.player)
                .ignoresSafeArea()
                .overlay(alignment: .topLeading) {
                    Button { video.player.pause(); playing = nil } label: {
                        Image(systemName: "xmark.circle.fill").font(.largeTitle).symbolRenderingMode(.palette).foregroundStyle(.white, .black.opacity(0.5))
                    }.padding().accessibilityLabel("Fechar vídeo")
                }
                .onAppear { video.player.play() }
        }
        .fileImporter(isPresented: $showPDF, allowedContentTypes: fileKind == .audio ? [.audio] : [.pdf]) { result in
            guard let target = importTarget else { return }
            switch result {
            case .success(let url):
                switch fileKind {
                case .pdf: model.importPDF(url, pageID: target.pageID, documentID: target.documentID)
                case .pdfPages: Task { await model.importPDFPages(url, after: target.pageID, documentID: target.documentID) }
                case .audio: Task { await model.insertAudio(from: url, transcribe: nil, pageID: target.pageID, documentID: target.documentID) }
                }
            case .failure(let error): model.error = error.localizedDescription
            }
        }
        .sheet(isPresented: $showRecorder) {
            let target = (page: pageID, document: document.id)
            AudioRecorderView { url, placement in
                Task {
                    await model.insertAudio(from: url, transcribe: placement, pageID: target.page, documentID: target.document)
                    try? FileManager.default.removeItem(at: url)
                }
            }.presentationDetents([.medium, .large])
        }
        .confirmationDialog("Onde colocar a transcrição?", isPresented: Binding(get: { transcribing != nil }, set: { if !$0 { transcribing = nil } }),
                            titleVisibility: .visible, presenting: transcribing) { id in
            Button("Bloco próprio ao lado do áudio") { Task { await model.transcribe(id, placement: .card) } }
            Button("Texto na nota, abaixo do áudio") { Task { await model.transcribe(id, placement: .text) } }
        }
        .onChange(of: document.id) { _, _ in tool = .select; session.hasTextSelection = false }
        // Opening a note puts the caret in its text and brings up the keyboard, ready to type.
        .task(id: document.id) {
            guard document.kind == .note, model.autofocusOnOpen else { return }
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled, model.document?.id == document.id, let focus = model.caretOnOpen() else { return }
            try? await Task.sleep(for: .milliseconds(120))
            session.focusText(focus)
        }
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
            onError: { error in
                if case .invalid(let text)? = error as? DocumentError { model.error = text } else { model.error = String(describing: error) }
            },
            onTranscribe: { id in transcribing = id },
            onPlayVideo: { id in
                if let block = document.blocks.first(where: { $0.id == id }), case .video(let reference) = block.content,
                   let media = model.mediaAsset(reference.hash) {
                    playing = PlayingVideo(id: id, player: AVPlayer(playerItem: AVPlayerItem(asset: media)))
                }
            },
            onReplaceImage: { id, png in model.replaceImage(id, png: png, pageID: targetPage, documentID: targetDocument) })
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

    /// Page thumbnails: a column beside the canvas on iPad, a grid (several per row) in the sheet.
    private func pagesPanel(sheet: Bool) -> some View {
        ScrollView {
            VStack(spacing: 14) {
                HStack {
                    if !sheet { Text("Páginas").font(.caption.weight(.semibold)).foregroundStyle(.secondary) }
                    Spacer()
                    Button { session.perform(.finish); model.addPage(); pageScrollRequest += 1 } label: {
                        Label("Nova página", systemImage: "plus").labelStyle(.iconOnly).font(.title3)
                    }
                    .accessibilityLabel("Adicionar página").accessibilityIdentifier("addPage")
                    .frame(minWidth: 36, minHeight: 36)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: sheet ? 96 : 100, maximum: sheet ? 130 : 120), spacing: 14)], spacing: 16) {
                    ForEach(Array(document.pages.enumerated()), id: \.element.id) { index, item in
                        if let previewPage = try? document.pageDocument(item.id) {
                            Button {
                                session.perform(.finish)
                                model.selectedPageID = item.id
                                pageScrollRequest += 1
                                showPages = false
                            } label: {
                                VStack(spacing: 6) {
                                    PageThumbnail(model: model, document: previewPage)
                                        .aspectRatio(document.canvas.size.width / document.canvas.size.height, contentMode: .fit)
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

    /// Tools in groups, side by side in a grid of tiles with large icons: two per row beside the
    /// canvas on iPad, as many as fit in the sheet on iPhone.
    private func toolsPanel(sheet: Bool) -> some View {
        // Not lazy: every tool exists (and is reachable by VoiceOver and tests) even when scrolled away.
        let columns = sheet ? 4 : 2
        return ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                toolSection("Desenhar") {
                    TileGrid(columns: columns, spacing: 8) {
                        ForEach(CanvasTool.allCases) { item in toolButton(item, sheet: sheet) }
                    }
                    HStack(spacing: 12) {
                        ColorPicker("Cor do traço", selection: $inkColor, supportsOpacity: false).labelsHidden()
                        Slider(value: $inkWidth, in: 1...20, step: 0.5).accessibilityLabel("Largura do traçado")
                        Text("\(inkWidth.formatted(.number.precision(.fractionLength(1))))").font(.caption2.monospacedDigit()).frame(width: 26)
                    }.disabled(tool == .eraser)
                    if tool == .eraser { Toggle("Apagar o traço inteiro", isOn: $vectorEraser).font(.caption) }
                }
                toolSection("Escrita vira texto") {
                    Toggle("Converter o que escrevo com a caneta", isOn: $handwritingToText).font(.caption)
                        .accessibilityIdentifier("handwritingToggle")
                    if handwritingToText {
                        Picker("Fonte", selection: $handwritingFont) {
                            ForEach(model.handwritingFonts, id: \.self) { name in
                                Text(HandwritingFonts.displayName(name)).font(.custom(name, size: 17)).tag(name)
                            }
                        }.pickerStyle(.menu).accessibilityIdentifier("handwritingFont")
                        Button("Importar fonte (.ttf, .otf)…") { importingFont = true }.font(.caption)
                    }
                }
                toolSection("Inserir") {
                    TileGrid(columns: columns, spacing: 8) {
                        tile("Texto", "text.badge.plus", sheet: sheet) { showTools = false; session.perform(.insertText) }
                        tile("Tabela", "tablecells", sheet: sheet) { showTools = false; session.perform(.insertTable) }
                        tile("Imagem", "photo", sheet: sheet) { beginImport(sticker: false, pdf: false) }
                        tile("PDF", "doc.richtext", sheet: sheet) { beginImport(sticker: false, pdf: true) }
                        if document.kind == .note {
                            tile("PDF para anotar", "doc.text.image", sheet: sheet) { beginImport(sticker: false, pdf: true, pages: true) }
                                .accessibilityIdentifier("pdfPages")
                        }
                        tile("Vídeo", "video", sheet: sheet) { beginImport(sticker: false, pdf: false, video: true) }
                        tile("Gravar áudio", "mic", sheet: sheet) {
                            session.perform(.finish)
                            afterToolsClose { showRecorder = true }
                        }.accessibilityIdentifier("recordAudio")
                        tile("Arquivo de áudio", "waveform", sheet: sheet) { beginImport(sticker: false, pdf: true, audio: true) }
                        tile("Sticker", "face.smiling", sheet: sheet) {
                            session.perform(.finish)
                            afterToolsClose { showStickers = true }
                        }
                    }
                }
                toolSection("Destacar") {
                    HStack(spacing: 10) {
                        highlight("Amarelo", .systemYellow)
                        highlight("Verde", .systemGreen)
                        highlight("Rosa", .systemPink)
                        Button { session.perform(.highlight(nil)) } label: { Image(systemName: "xmark.circle").font(.title2) }
                            .accessibilityLabel("Limpar destaque")
                    }.disabled(!session.hasTextSelection || tool.isDrawing)
                }
                if document.kind == .note {
                    toolSection("Página") {
                        TileGrid(columns: columns, spacing: 8) {
                            tile("Cabeçalho e rodapé", "rectangle.topthird.inset.filled", sheet: sheet) {
                                session.perform(.finish); openPageSetup(.bands)
                            }.accessibilityIdentifier("headerFooter")
                            tile("Numerar páginas", "number", sheet: sheet) {
                                session.perform(.finish); openPageSetup(.numbers)
                            }.accessibilityIdentifier("pageNumbers")
                            tile("Papel", "squareshape.split.3x3", sheet: sheet) {
                                session.perform(.finish)
                                afterToolsClose { showPaper = true }
                            }.accessibilityIdentifier("paperStyle")
                        }
                    }
                }
                if !sheet { Text("Dois dedos para mover ao desenhar").font(.system(size: 10)).foregroundStyle(.secondary) }
            }.padding(.horizontal, sheet ? 18 : 10).padding(.vertical, 14)
        }.background(.bar)
    }
    private func toolSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            content()
        }
    }
    private func toolButton(_ item: CanvasTool, sheet: Bool) -> some View {
        tile(item.title, item.symbol, sheet: sheet, selected: tool == item) {
            session.perform(.finish); tool = item
            if item.isDrawing { showTools = false }
        }.accessibilityIdentifier("tool-\(item.rawValue)")
    }
    private func tile(_ title: String, _ symbol: String, sheet: Bool, selected: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: sheet ? 28 : 24, weight: .regular)).frame(height: sheet ? 32 : 28)
                if sheet { Text(title).font(.system(size: 10, weight: .medium)).lineLimit(2).multilineTextAlignment(.center).minimumScaleFactor(0.8) }
            }
            .frame(maxWidth: .infinity, minHeight: sheet ? 66 : 50)
            .foregroundStyle(selected ? Color.accentColor : Color.primary)
            .background(selected ? Color.accentColor.opacity(0.14) : Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(.plain).accessibilityLabel(title).accessibilityAddTraits(selected ? .isSelected : [])
    }
    private func highlight(_ title: String, _ color: UIColor) -> some View {
        Button { session.perform(.highlight(color.withAlphaComponent(0.35))) } label: {
            Circle().fill(Color(uiColor: color)).frame(width: 28, height: 28)
                .overlay(Circle().stroke(.primary.opacity(0.12), lineWidth: 1))
        }.accessibilityLabel("Destacar em \(title)")
    }
    private func openPageSetup(_ focus: PageSetupView.Focus) { afterToolsClose { pageSetup = focus } }

    /// Runs `open` once the tools sheet has closed (iPhone), or right away beside the canvas (iPad).
    private func afterToolsClose(_ open: @escaping () -> Void) {
        if showTools { afterTools = open; showTools = false } else { open() }
    }
    private func beginImport(sticker: Bool, pdf: Bool, audio: Bool = false, video: Bool = false, pages: Bool = false) {
        session.perform(.finish)
        fileKind = audio ? .audio : pages ? .pdfPages : .pdf
        pickingVideo = video
        importTarget = .init(documentID: document.id, pageID: pageID, sticker: sticker)
        afterToolsClose { if pdf { showPDF = true } else { showPhotos = true } }
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

/// A video picked from the gallery, copied to a temporary file (videos can be large: no Data).
struct PickedMovie: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in SentTransferredFile(movie.url) } importing: { received in
            let copy = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension)
            try FileManager.default.copyItem(at: received.file, to: copy)
            return PickedMovie(url: copy)
        }
    }
}

/// Tiles in rows of equal width, as many per row as `columns`; each row as tall as its tallest tile.
struct TileGrid: Layout {
    var columns: Int
    var spacing: CGFloat

    private func width(_ proposal: ProposedViewSize) -> CGFloat {
        let total = proposal.width ?? CGFloat(columns) * 72
        return max(1, (total - spacing * CGFloat(columns - 1)) / CGFloat(columns))
    }
    private func rows(_ subviews: Subviews, width: CGFloat) -> [CGFloat] {
        stride(from: 0, to: subviews.count, by: columns).map { start in
            subviews[start..<min(subviews.count, start + columns)].map { $0.sizeThatFits(.init(width: width, height: nil)).height }.max() ?? 0
        }
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let w = width(proposal), heights = rows(subviews, width: w)
        return CGSize(width: proposal.width ?? w * CGFloat(columns) + spacing * CGFloat(columns - 1),
                      height: heights.reduce(0, +) + spacing * CGFloat(max(0, heights.count - 1)))
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let w = width(ProposedViewSize(width: bounds.width, height: nil)), heights = rows(subviews, width: w)
        var y = bounds.minY
        for (row, height) in heights.enumerated() {
            for column in 0..<columns {
                let index = row * columns + column
                guard index < subviews.count else { break }
                subviews[index].place(at: CGPoint(x: bounds.minX + CGFloat(column) * (w + spacing), y: y), proposal: .init(width: w, height: height))
            }
            y += height + spacing
        }
    }
}

