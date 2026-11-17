#if canImport(UIKit)
import UIKit
import GotItDomain
import GotItCanvas

/// Preview of background removal before it touches the note. The user picks how the background
/// is found — "Objeto da foto" (Vision subject lifting) or "Papel ou quadro" (drawings and writing,
/// with a sensitivity slider) — and can retouch the result with a brush: "Apagar" clears what was
/// kept by mistake, "Recuperar" brings back what was removed (the original shows faintly beneath),
/// with an adjustable tip, pinch to zoom (two fingers move) and undo. Nothing changes until "Aplicar".
@MainActor final class CutoutPreviewController: UIViewController, UIScrollViewDelegate {
    enum Brush: Int { case look, erase, restore }

    private let source: RasterImage
    private let onApply: (ImageCutout.Processed) -> Void
    private(set) var method: ImageCutout.Method
    private(set) var sensitivity = 0.5
    private(set) var result: ImageCutout.Processed?
    /// Alpha of the cut-out being retouched (one byte per pixel) and the steps to undo.
    private(set) var mask: [UInt8] = []
    private var history: [[UInt8]] = []
    private var work: Task<Void, Never>?
    private var sourceAlpha: [UInt8] = []

    let modes = UISegmentedControl(items: ["Objeto da foto", "Papel ou quadro"])
    let slider = UISlider()
    let brushes = UISegmentedControl(items: [UIImage(systemName: "hand.point.up.left")!, UIImage(systemName: "eraser")!, UIImage(systemName: "paintbrush.pointed")!])
    let brushSize = UISlider()
    let undoButton = UIButton(type: .system)
    private let sliderRow = UIStackView()
    private let scroll = UIScrollView()
    private let canvas = UIView()
    private let original = UIImageView()
    private let preview = UIImageView()
    private let stroke = CAShapeLayer()
    private let note = UILabel()
    private let spinner = UIActivityIndicatorView(style: .large)
    private var applyButton: UIBarButtonItem!
    private var path: [CGPoint] = []
    private var painting: UIPanGestureRecognizer!

    init(source: RasterImage, onApply: @escaping (ImageCutout.Processed) -> Void) {
        self.source = source; self.onApply = onApply
        method = ImageCutout.looksLikePaper(source) ? .paper : .subject
        sourceAlpha = (0..<(source.width * source.height)).map { source.alpha($0) }
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    var brush: Brush { Brush(rawValue: brushes.selectedSegmentIndex) ?? .look }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Remover fundo"
        view.backgroundColor = .systemGroupedBackground
        navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .cancel, primaryAction: UIAction { [weak self] _ in
            self?.work?.cancel(); self?.dismiss(animated: true)
        })
        applyButton = UIBarButtonItem(title: "Aplicar", primaryAction: UIAction { [weak self] _ in self?.apply() })
        applyButton.style = .done; applyButton.isEnabled = false
        navigationItem.rightBarButtonItem = applyButton

        modes.selectedSegmentIndex = method == .subject ? 0 : 1
        modes.accessibilityIdentifier = "cutoutMode"
        modes.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.method = self.modes.selectedSegmentIndex == 0 ? .subject : .paper
            self.update(); self.refresh(after: 0)
        }, for: .valueChanged)
        slider.minimumValue = 0; slider.maximumValue = 1; slider.value = Float(sensitivity)
        slider.accessibilityLabel = "Sensibilidade aos traços"
        slider.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.sensitivity = Double(self.slider.value); self.refresh(after: 0.25)
        }, for: .valueChanged)
        let firm = UILabel(), faint = UILabel()
        firm.text = "Só traços firmes"; faint.text = "Traços fracos também"
        for label in [firm, faint] { label.font = .preferredFont(forTextStyle: .caption1); label.textColor = .secondaryLabel }
        sliderRow.axis = .horizontal; sliderRow.spacing = 8; sliderRow.alignment = .center
        [firm, slider, faint].forEach(sliderRow.addArrangedSubview)

        // Preview: the cut-out on a checkerboard, zoomable; the original shows faintly while retouching.
        scroll.delegate = self; scroll.minimumZoomScale = 1; scroll.maximumZoomScale = 8
        scroll.backgroundColor = UIColor(patternImage: Self.checkerboard)
        scroll.layer.cornerRadius = 12; scroll.clipsToBounds = true
        scroll.showsHorizontalScrollIndicator = false; scroll.showsVerticalScrollIndicator = false
        scroll.addSubview(canvas)
        for imageView in [original, preview] {
            imageView.contentMode = .scaleAspectFit
            imageView.translatesAutoresizingMaskIntoConstraints = true
            imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            canvas.addSubview(imageView)
        }
        original.image = ImageCutout.cgImage(source).map { UIImage(cgImage: $0) }
        original.alpha = 0
        preview.accessibilityIdentifier = "cutoutPreview"
        stroke.fillColor = nil; stroke.lineCap = .round; stroke.lineJoin = .round
        canvas.layer.addSublayer(stroke)
        painting = UIPanGestureRecognizer(target: self, action: #selector(paint(_:)))
        painting.maximumNumberOfTouches = 1
        canvas.addGestureRecognizer(painting)

        brushes.selectedSegmentIndex = Brush.look.rawValue
        brushes.accessibilityIdentifier = "cutoutBrush"
        brushes.setAccessibilityLabelsForSegments(["Ver e mover", "Apagar", "Recuperar"])
        brushes.addAction(UIAction { [weak self] _ in self?.brushChanged() }, for: .valueChanged)
        brushSize.minimumValue = 6; brushSize.maximumValue = 80; brushSize.value = 24
        brushSize.accessibilityLabel = "Tamanho do pincel"
        brushSize.minimumValueImage = UIImage(systemName: "circle.fill")?.withConfiguration(UIImage.SymbolConfiguration(pointSize: 6))
        brushSize.maximumValueImage = UIImage(systemName: "circle.fill")?.withConfiguration(UIImage.SymbolConfiguration(pointSize: 18))
        undoButton.setImage(UIImage(systemName: "arrow.uturn.backward"), for: .normal)
        undoButton.accessibilityLabel = "Desfazer retoque"; undoButton.isEnabled = false
        undoButton.addAction(UIAction { [weak self] _ in self?.undoRetouch() }, for: .touchUpInside)
        let brushRow = UIStackView(arrangedSubviews: [brushes, brushSize, undoButton])
        brushRow.axis = .horizontal; brushRow.spacing = 12; brushRow.alignment = .center
        brushes.setContentHuggingPriority(.required, for: .horizontal)

        note.font = .preferredFont(forTextStyle: .footnote); note.textColor = .secondaryLabel; note.numberOfLines = 0; note.textAlignment = .center

        let stack = UIStackView(arrangedSubviews: [modes, sliderRow, scroll, brushRow, note])
        stack.axis = .vertical; stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        spinner.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(spinner)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
            spinner.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
        ])
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        update(); brushChanged(); refresh(after: 0)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard scroll.zoomScale == 1 else { return }
        canvas.frame = CGRect(origin: .zero, size: scroll.bounds.size)
        scroll.contentSize = scroll.bounds.size
        original.frame = canvas.bounds; preview.frame = canvas.bounds
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { canvas }

    private func update() { sliderRow.isHidden = method != .paper }

    private func brushChanged() {
        // Painting takes one finger; moving the zoomed picture then takes two.
        scroll.panGestureRecognizer.minimumNumberOfTouches = brush == .look ? 1 : 2
        painting.isEnabled = brush != .look
        UIView.animate(withDuration: 0.2) { self.original.alpha = self.brush == .restore ? 0.3 : 0 }
        brushSize.isEnabled = brush != .look
    }

    /// Recomputes off the main thread; a newer change cancels the one in flight. Retouches are
    /// made on a result, so a new result starts without them.
    func refresh(after delay: Double) {
        work?.cancel()
        applyButton?.isEnabled = false; spinner.startAnimating()
        let source = source, method = method, sensitivity = sensitivity
        work = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled else { return }
            let processed = await Task.detached(priority: .userInitiated) {
                ImageCutout.process(source, method: method, sensitivity: sensitivity)
            }.value
            guard !Task.isCancelled, let self else { return }
            self.show(processed)
        }
    }

    private func show(_ processed: ImageCutout.Processed) {
        result = processed
        let image = processed.cutout.image
        mask = (0..<(image.width * image.height)).map { image.alpha($0) }
        history = []; undoButton.isEnabled = false
        spinner.stopAnimating()
        redraw()
        note.text = processed.note ?? (processed.cutout.method == .subject ? "Objeto recortado pelo Vision. Use Apagar ou Recuperar para acertar as bordas."
                                                                           : "Papel removido. Use Apagar ou Recuperar para acertar o resultado.")
        modes.selectedSegmentIndex = processed.cutout.method == .subject ? 0 : 1
        if processed.cutout.method != method { method = processed.cutout.method; update() }
        applyButton.isEnabled = true
    }

    private func redraw() {
        guard let result else { return }
        preview.image = ImageCutout.cgImage(ImageCutout.composed(result.cutout.image, source: source, mask: mask)).map { UIImage(cgImage: $0) }
    }

    /// Where the picture is drawn inside the (unzoomed) preview.
    private var pictureRect: CGRect {
        guard let image = result?.cutout.image else { return .zero }
        let box = canvas.bounds, scale = min(box.width / CGFloat(image.width), box.height / CGFloat(image.height))
        let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        return CGRect(x: box.midX - size.width / 2, y: box.midY - size.height / 2, width: size.width, height: size.height)
    }

    /// Brush tip on screen, in the preview's (unzoomed) coordinates.
    private var tipRadius: CGFloat { CGFloat(brushSize.value) / 2 / max(1, scroll.zoomScale) }

    @objc private func paint(_ gesture: UIPanGestureRecognizer) {
        guard brush != .look, result != nil else { return }
        let point = gesture.location(in: canvas)
        switch gesture.state {
        case .began:
            path = [point]
            stroke.strokeColor = (brush == .erase ? UIColor.systemRed : UIColor.systemGreen).withAlphaComponent(0.45).cgColor
            stroke.lineWidth = tipRadius * 2
            drawStroke()
        case .changed:
            path.append(point); drawStroke()
        case .ended:
            path.append(point)
            let rect = pictureRect
            guard rect.width > 0, let image = result?.cutout.image else { path = []; drawStroke(); return }
            let perPixel = CGFloat(image.width) / rect.width
            let pixels = path.map { CanvasPoint(x: Double(($0.x - rect.minX) * perPixel), y: Double(($0.y - rect.minY) * perPixel)) }
            paint(pixels, radius: Double(tipRadius * perPixel), mode: brush == .erase ? .erase : .restore)
            path = []; drawStroke()
        default:
            path = []; drawStroke()
        }
    }

    private func drawStroke() {
        guard let first = path.first else { stroke.path = nil; return }
        let line = UIBezierPath()
        line.move(to: first)
        for point in path.dropFirst() { line.addLine(to: point) }
        if path.count == 1 { line.addLine(to: CGPoint(x: first.x + 0.1, y: first.y)) }
        stroke.frame = canvas.bounds; stroke.path = line.cgPath
    }

    /// One brush stroke on the mask, in the picture's pixels (also used by tests).
    func paint(_ pixels: [CanvasPoint], radius: Double, mode: MaskBrush.Mode) {
        guard let image = result?.cutout.image else { return }
        history.append(mask); if history.count > 20 { history.removeFirst() }
        let sameSize = image.width == source.width && image.height == source.height
        MaskBrush.paint(&mask, width: image.width, height: image.height, path: pixels, radius: radius, mode: mode,
                        limit: sameSize ? sourceAlpha : nil)
        undoButton.isEnabled = true
        redraw()
    }

    func undoRetouch() {
        guard let previous = history.popLast() else { return }
        mask = previous; undoButton.isEnabled = !history.isEmpty
        redraw()
    }

    /// Waits for the preview in progress (tests).
    func finished() async { while result == nil || spinner.isAnimating { try? await Task.sleep(for: .milliseconds(30)) } }

    func apply() {
        guard var result else { return }
        result.cutout.image = ImageCutout.composed(result.cutout.image, source: source, mask: mask)
        dismiss(animated: true)
        onApply(result)
    }

    private static let checkerboard: UIImage = {
        let size = CGSize(width: 16, height: 16)
        return UIGraphicsImageRenderer(size: size).image { context in
            UIColor.white.setFill(); context.fill(CGRect(origin: .zero, size: size))
            UIColor(white: 0.88, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8)); context.fill(CGRect(x: 8, y: 8, width: 8, height: 8))
        }
    }()
}

private extension UISegmentedControl {
    func setAccessibilityLabelsForSegments(_ labels: [String]) {
        for (index, label) in labels.enumerated() where index < numberOfSegments {
            if let image = imageForSegment(at: index) { image.accessibilityLabel = label; setImage(image, forSegmentAt: index) }
        }
    }
}
#endif
