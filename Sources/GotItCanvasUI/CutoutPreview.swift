#if canImport(UIKit)
import UIKit
import GotItDomain
import GotItCanvas

/// Preview of background removal (and vectorising) before it touches the note: the user picks
/// how the background is found — "Objeto da foto" (Vision subject lifting) or "Papel ou quadro"
/// (drawings and writing) — and, for paper, how faint a mark still counts as ink. Nothing changes
/// until "Aplicar".
@MainActor final class CutoutPreviewController: UIViewController {
    private let source: RasterImage
    private let vectorize: Bool
    private let onApply: (ImageCutout.Processed) -> Void
    private(set) var method: ImageCutout.Method
    private(set) var sensitivity = 0.5
    private(set) var result: ImageCutout.Processed?
    private var work: Task<Void, Never>?

    let modes = UISegmentedControl(items: ["Objeto da foto", "Papel ou quadro"])
    let slider = UISlider()
    private let sliderRow = UIStackView()
    private let preview = UIImageView()
    private let note = UILabel()
    private let spinner = UIActivityIndicatorView(style: .large)
    private var applyButton: UIBarButtonItem!

    init(source: RasterImage, vectorize: Bool, onApply: @escaping (ImageCutout.Processed) -> Void) {
        self.source = source; self.vectorize = vectorize; self.onApply = onApply
        method = ImageCutout.looksLikePaper(source) ? .paper : .subject
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = vectorize ? "Vetorizar traços" : "Remover fundo"
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

        preview.contentMode = .scaleAspectFit
        preview.backgroundColor = UIColor(patternImage: Self.checkerboard)
        preview.layer.cornerRadius = 12; preview.clipsToBounds = true
        preview.accessibilityIdentifier = "cutoutPreview"
        note.font = .preferredFont(forTextStyle: .footnote); note.textColor = .secondaryLabel; note.numberOfLines = 0; note.textAlignment = .center

        let stack = UIStackView(arrangedSubviews: [modes, sliderRow, preview, note])
        stack.axis = .vertical; stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        spinner.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(spinner)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
            spinner.centerXAnchor.constraint(equalTo: preview.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: preview.centerYAnchor),
        ])
        preview.setContentHuggingPriority(.defaultLow, for: .vertical)
        update(); refresh(after: 0)
    }

    private func update() { sliderRow.isHidden = method != .paper }

    /// Recomputes off the main thread; a newer change cancels the one in flight.
    func refresh(after delay: Double) {
        work?.cancel()
        applyButton?.isEnabled = false; spinner.startAnimating()
        let source = source, method = method, sensitivity = sensitivity, vectorize = vectorize
        work = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled else { return }
            let processed = await Task.detached(priority: .userInitiated) {
                ImageCutout.process(source, method: method, sensitivity: sensitivity, vectorize: vectorize)
            }.value
            guard !Task.isCancelled, let self else { return }
            self.show(processed)
        }
    }

    private func show(_ processed: ImageCutout.Processed) {
        result = processed
        spinner.stopAnimating()
        let shown = processed.strokePreview ?? processed.cutout.image
        preview.image = ImageCutout.cgImage(shown).map { UIImage(cgImage: $0) }
        note.text = processed.note ?? (vectorize ? "\(processed.traced.count) traços. Depois de aplicar, cada um pode ser apagado, recolorido ou movido como um traço da caneta."
                                                  : (processed.cutout.method == .subject ? "Objeto recortado pelo Vision." : "Papel removido."))
        modes.selectedSegmentIndex = processed.cutout.method == .subject ? 0 : 1
        if processed.cutout.method != method { method = processed.cutout.method; update() }
        applyButton.isEnabled = !vectorize || !processed.traced.isEmpty
    }

    /// Waits for the preview in progress (tests).
    func finished() async { while result == nil || spinner.isAnimating { try? await Task.sleep(for: .milliseconds(30)) } }

    func apply() {
        guard let result else { return }
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
#endif
