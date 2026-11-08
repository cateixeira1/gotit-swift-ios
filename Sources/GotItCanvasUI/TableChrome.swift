#if canImport(UIKit)
import UIKit
import GotItDomain

/// Which line of a table the user picked by tapping its first cell: a row (first column),
/// a column (first row), or both for the corner cell.
public struct TableFocus: Equatable, Sendable {
    public var block: UUID
    public var row: Int?
    public var column: Int?

    /// The first cell of a row is in column 0, the first cell of a column in row 0.
    public static func picked(block: UUID, row: Int, column: Int) -> TableFocus? {
        guard row == 0 || column == 0 else { return nil }
        return TableFocus(block: block, row: column == 0 ? row : nil, column: row == 0 ? column : nil)
    }
}

/// Controls over a selected table: "+" buttons that add a row (below) and a column (right),
/// a tint over the focused row/column and a handle on its far edge to resize it.
/// Lives on the surface with the table's center and transform, like `SelectionHandles`;
/// only the controls take touches, so taps on cells still reach the table.
@MainActor final class TableChrome: UIView {
    enum Axis { case row, column }
    var table: CanvasTable { didSet { setNeedsLayout() } }
    var focus: TableFocus?
    var onAddRow: (() -> Void)?
    var onAddColumn: (() -> Void)?
    /// (axis, index, new size in table points, finished)
    var onResize: ((Axis, Int, Double, Bool) -> Void)?

    let addRow = UIButton(type: .system), addColumn = UIButton(type: .system)
    let rowHandle = UIView(), columnHandle = UIView()
    private let rowBand = UIView(), columnBand = UIView()
    private var startSize = 0.0

    init(table: CanvasTable, focus: TableFocus?) {
        self.table = table; self.focus = focus
        super.init(frame: .zero)
        backgroundColor = .clear
        for band in [rowBand, columnBand] {
            band.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.14)
            band.layer.borderColor = UIColor.systemBlue.cgColor; band.layer.borderWidth = 2
            band.isUserInteractionEnabled = false; addSubview(band)
        }
        for (button, title, id) in [(addRow, "Adicionar linha", "tableAddRow"), (addColumn, "Adicionar coluna", "tableAddColumn")] {
            var config = UIButton.Configuration.filled()
            config.image = UIImage(systemName: "plus", withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .bold))
            config.cornerStyle = .capsule; config.contentInsets = .init(top: 6, leading: 6, bottom: 6, trailing: 6)
            button.configuration = config
            button.accessibilityLabel = title; button.accessibilityIdentifier = id
            addSubview(button)
        }
        addRow.addAction(UIAction { [weak self] _ in self?.onAddRow?() }, for: .touchUpInside)
        addColumn.addAction(UIAction { [weak self] _ in self?.onAddColumn?() }, for: .touchUpInside)
        for (handle, title, id) in [(rowHandle, "Altura da linha", "tableRowHandle"), (columnHandle, "Largura da coluna", "tableColumnHandle")] {
            handle.backgroundColor = .systemBlue
            handle.layer.cornerRadius = 4; handle.layer.borderColor = UIColor.white.cgColor; handle.layer.borderWidth = 2
            handle.isAccessibilityElement = true; handle.accessibilityLabel = title; handle.accessibilityIdentifier = id
            handle.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(drag(_:))))
            addSubview(handle)
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    private var scale: CGSize {
        CGSize(width: bounds.width / max(1, table.width), height: bounds.height / max(1, table.height))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let s = scale
        addRow.frame = CGRect(x: bounds.midX - 15, y: bounds.maxY + 8, width: 30, height: 30)
        addColumn.frame = CGRect(x: bounds.maxX + 8, y: bounds.midY - 15, width: 30, height: 30)
        // A table at the page edge: the button would be off the page, where touches do not arrive.
        if let page = superview?.bounds {
            if !page.contains(convert(addRow.frame, to: superview)) { addRow.frame.origin.y = bounds.maxY - 38 }
            if !page.contains(convert(addColumn.frame, to: superview)) { addColumn.frame.origin.x = bounds.maxX - 38 }
        }
        if let row = focus?.row, table.rowHeights.indices.contains(row) {
            let f = table.frame(row: row, column: 0)
            rowBand.frame = CGRect(x: 0, y: f.y * s.height, width: bounds.width, height: f.height * s.height)
            let x = min(bounds.width / 2, CGFloat(table.columnWidths[0]) * s.width / 2)
            rowHandle.frame = CGRect(x: x - 18, y: (f.y + f.height) * s.height - 5, width: 36, height: 10)
            rowBand.isHidden = false; rowHandle.isHidden = false
        } else { rowBand.isHidden = true; rowHandle.isHidden = true }
        if let column = focus?.column, table.columnWidths.indices.contains(column) {
            let f = table.frame(row: 0, column: column)
            columnBand.frame = CGRect(x: f.x * s.width, y: 0, width: f.width * s.width, height: bounds.height)
            let y = min(bounds.height / 2, CGFloat(table.rowHeights[0]) * s.height / 2)
            columnHandle.frame = CGRect(x: (f.x + f.width) * s.width - 5, y: y - 18, width: 10, height: 36)
            columnBand.isHidden = false; columnHandle.isHidden = false
        } else { columnBand.isHidden = true; columnHandle.isHidden = true }
    }

    /// Only the visible controls take touches (with a generous margin around the thin handles).
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        for handle in [rowHandle, columnHandle] where !handle.isHidden && handle.frame.insetBy(dx: -14, dy: -14).contains(point) { return handle }
        for button in [addRow, addColumn] where button.frame.insetBy(dx: -6, dy: -6).contains(point) { return button }
        return nil
    }

    @objc private func drag(_ gesture: UIPanGestureRecognizer) {
        guard let handle = gesture.view else { return }
        let axis: Axis = handle === rowHandle ? .row : .column
        guard let index = axis == .row ? focus?.row : focus?.column else { return }
        switch gesture.state {
        case .began:
            startSize = axis == .row ? table.rowHeights[index] : table.columnWidths[index]
        case .changed, .ended:
            // The view moves while it resizes, so measure in the surface and undo the rotation.
            let moved = gesture.translation(in: superview)
            let local = CGSize(width: moved.x, height: moved.y).applying(transform.inverted())
            let s = scale
            let size = axis == .row ? startSize + Double(local.height / max(0.01, s.height))
                                    : startSize + Double(local.width / max(0.01, s.width))
            onResize?(axis, index, size, gesture.state == .ended)
        case .cancelled, .failed:
            onResize?(axis, index, startSize, true)
        default: break
        }
    }
}
#endif
