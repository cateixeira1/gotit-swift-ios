#if canImport(UIKit)
import UIKit

@MainActor final class SelectionHandles: UIView {
    var onResize: ((CGFloat, CGFloat, Bool, Bool, Bool) -> Void)?
    private var handles: [UIView] = []
    /// Crop mode: same corners, different look and meaning (trim instead of scale).
    var cropping = false {
        didSet {
            layer.borderColor = (cropping ? UIColor.label : UIColor.systemBlue).cgColor
            layer.borderWidth = cropping ? 2 : 1
            for handle in handles {
                handle.backgroundColor = cropping ? .label : .systemBlue
                handle.layer.cornerRadius = cropping ? 3 : 7
                handle.accessibilityLabel = "\(cropping ? "Recortar" : "Redimensionar") canto \(handle.tag + 1)"
                handle.accessibilityIdentifier = "\(cropping ? "crop" : "resize")-handle-\(handle.tag)"
            }
        }
    }
    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.borderColor = UIColor.systemBlue.cgColor; layer.borderWidth = 1
        for i in 0..<4 {
            let handle = UIView(); handle.tag = i; handle.backgroundColor = .systemBlue
            handle.layer.cornerRadius = 7; handle.layer.borderColor = UIColor.white.cgColor; handle.layer.borderWidth = 2
            handle.accessibilityLabel = "Redimensionar canto \(i + 1)"; handle.isAccessibilityElement = true
            handle.accessibilityIdentifier = "resize-handle-\(i)"
            handle.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(drag(_:))))
            addSubview(handle); handles.append(handle)
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layoutSubviews() {
        super.layoutSubviews()
        for (i, handle) in handles.enumerated() {
            handle.frame = CGRect(x: (i % 2 == 0 ? 0 : bounds.width) - 14, y: (i < 2 ? 0 : bounds.height) - 14, width: 28, height: 28)
        }
    }
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        for handle in handles where handle.frame.insetBy(dx: -8, dy: -8).contains(point) { return handle }
        return nil
    }
    @objc private func drag(_ gesture: UIPanGestureRecognizer) {
        guard let handle = gesture.view else { return }
        let d = gesture.translation(in: self)
        if gesture.state == .changed || gesture.state == .ended { onResize?(d.x, d.y, handle.tag % 2 == 0, handle.tag < 2, gesture.state == .ended) }
        if gesture.state == .cancelled { onResize?(0, 0, false, false, true) }
    }
}
#endif
