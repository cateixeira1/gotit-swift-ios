import Foundation

/// A simple word-processor table: a grid of rich-text cells. Sizes are logical points; the
/// block frame always equals the sum of column widths by the sum of row heights.
/// Merged cells and formulas are intentionally absent; both can be added as optional fields.
public struct TableCell: Codable, Equatable, Sendable {
    public var text: RichText
    public var background: String?
    public init(text: RichText = .init(""), background: String? = nil) { self.text = text; self.background = background }
}

public struct CanvasTable: Codable, Equatable, Sendable {
    public var columnWidths: [Double]
    public var rowHeights: [Double]
    /// Row-major: `cells[row][column]`.
    public var cells: [[TableCell]]
    public var headerRow: Bool
    public var borderColor: String
    public var borderWidth: Double

    public static let maximumRows = 500, maximumColumns = 40
    public static let minimumColumnWidth = 24.0, minimumRowHeight = 24.0

    public init(rows: Int, columns: Int, width: Double, rowHeight: Double = 36, headerRow: Bool = true,
                borderColor: String = "#9CA3AF", borderWidth: Double = 1) {
        let rows = max(1, rows), columns = max(1, columns)
        columnWidths = Array(repeating: max(Self.minimumColumnWidth, width / Double(columns)), count: columns)
        rowHeights = Array(repeating: max(Self.minimumRowHeight, rowHeight), count: rows)
        cells = Array(repeating: Array(repeating: TableCell(), count: columns), count: rows)
        self.headerRow = headerRow; self.borderColor = borderColor; self.borderWidth = borderWidth
    }

    public var rowCount: Int { rowHeights.count }
    public var columnCount: Int { columnWidths.count }
    public var width: Double { columnWidths.reduce(0, +) }
    public var height: Double { rowHeights.reduce(0, +) }

    /// Cell rectangle in the table's own coordinates.
    public func frame(row: Int, column: Int) -> LogicalRect {
        LogicalRect(x: columnWidths[..<column].reduce(0, +), y: rowHeights[..<row].reduce(0, +),
                    width: columnWidths[column], height: rowHeights[row])
    }

    /// Hit test in table coordinates; points on the outer edge belong to the last row/column.
    public func cell(at point: CanvasPoint) -> (row: Int, column: Int)? {
        guard point.x >= 0, point.y >= 0, point.x <= width, point.y <= height else { return nil }
        func index(_ value: Double, _ sizes: [Double]) -> Int {
            var edge = 0.0
            for (i, size) in sizes.enumerated() { edge += size; if value < edge { return i } }
            return sizes.count - 1
        }
        return (index(point.y, rowHeights), index(point.x, columnWidths))
    }

    /// Text of all cells, tab-separated columns and newline-separated rows (search, export).
    public var plainText: String {
        cells.map { $0.map(\.text.plainText).joined(separator: "\t") }.joined(separator: "\n")
    }

    // MARK: Structural edits. Each returns a new table; invalid indices throw.

    public func insertingRow(at index: Int) throws -> CanvasTable {
        guard (0...rowCount).contains(index), rowCount < Self.maximumRows else { throw DocumentError.invalid("Invalid row insertion") }
        var copy = self
        let height = rowHeights[min(index, rowCount - 1)]
        copy.rowHeights.insert(height, at: index)
        copy.cells.insert(Array(repeating: TableCell(), count: columnCount), at: index)
        return copy
    }

    public func removingRow(at index: Int) throws -> CanvasTable {
        guard rowHeights.indices.contains(index), rowCount > 1 else { throw DocumentError.invalid("A table keeps at least one row") }
        var copy = self
        copy.rowHeights.remove(at: index); copy.cells.remove(at: index)
        return copy
    }

    /// The new column takes the width of its neighbour; the table grows by that width.
    public func insertingColumn(at index: Int) throws -> CanvasTable {
        guard (0...columnCount).contains(index), columnCount < Self.maximumColumns else { throw DocumentError.invalid("Invalid column insertion") }
        var copy = self
        copy.columnWidths.insert(columnWidths[min(index, columnCount - 1)], at: index)
        for row in copy.cells.indices { copy.cells[row].insert(TableCell(), at: index) }
        return copy
    }

    public func removingColumn(at index: Int) throws -> CanvasTable {
        guard columnWidths.indices.contains(index), columnCount > 1 else { throw DocumentError.invalid("A table keeps at least one column") }
        var copy = self
        copy.columnWidths.remove(at: index)
        for row in copy.cells.indices { copy.cells[row].remove(at: index) }
        return copy
    }

    /// A copy of the row (texts, colours and height) right below it.
    public func duplicatingRow(at index: Int) throws -> CanvasTable {
        guard rowHeights.indices.contains(index), rowCount < Self.maximumRows else { throw DocumentError.invalid("Invalid row duplication") }
        var copy = self
        copy.rowHeights.insert(rowHeights[index], at: index + 1)
        copy.cells.insert(cells[index], at: index + 1)
        return copy
    }

    /// A copy of the column (texts, colours and width) right after it.
    public func duplicatingColumn(at index: Int) throws -> CanvasTable {
        guard columnWidths.indices.contains(index), columnCount < Self.maximumColumns else { throw DocumentError.invalid("Invalid column duplication") }
        var copy = self
        copy.columnWidths.insert(columnWidths[index], at: index + 1)
        for row in copy.cells.indices { copy.cells[row].insert(cells[row][index], at: index + 1) }
        return copy
    }

    public static let maximumLineSize = 4000.0

    /// Manual size of one row (resize handle); the table grows or shrinks by the difference.
    public func settingRowHeight(_ height: Double, at index: Int) throws -> CanvasTable {
        guard rowHeights.indices.contains(index), height.isFinite else { throw DocumentError.invalid("Invalid row height") }
        var copy = self; copy.rowHeights[index] = min(Self.maximumLineSize, max(Self.minimumRowHeight, height)); return copy
    }

    /// Manual size of one column (resize handle); the table grows or shrinks by the difference.
    public func settingColumnWidth(_ width: Double, at index: Int) throws -> CanvasTable {
        guard columnWidths.indices.contains(index), width.isFinite else { throw DocumentError.invalid("Invalid column width") }
        var copy = self; copy.columnWidths[index] = min(Self.maximumLineSize, max(Self.minimumColumnWidth, width)); return copy
    }

    public func settingText(_ text: RichText, row: Int, column: Int) throws -> CanvasTable {
        guard cells.indices.contains(row), cells[row].indices.contains(column) else { throw DocumentError.invalid("Missing table cell") }
        var copy = self; copy.cells[row][column].text = text; return copy
    }

    /// Grows a row so its tallest cell fits (`needed` comes from text measurement in the UI);
    /// never shrinks below the row's current height, so manual sizes are respected.
    public func fittingRow(_ row: Int, toContentHeight needed: Double) throws -> CanvasTable {
        guard rowHeights.indices.contains(row), needed.isFinite else { throw DocumentError.invalid("Invalid row fit") }
        var copy = self; copy.rowHeights[row] = max(rowHeights[row], needed, Self.minimumRowHeight); return copy
    }

    /// Proportional scale, used when the block is resized with its handles.
    public func scaled(toWidth newWidth: Double, height newHeight: Double) -> CanvasTable {
        guard width > 0, height > 0, newWidth.isFinite, newHeight.isFinite, newWidth > 0, newHeight > 0 else { return self }
        var copy = self
        let sx = newWidth / width, sy = newHeight / height
        copy.columnWidths = columnWidths.map { max(Self.minimumColumnWidth, $0 * sx) }
        copy.rowHeights = rowHeights.map { max(Self.minimumRowHeight, $0 * sy) }
        return copy
    }
}

public extension CanvasBlock {
    /// Applies a table edit and keeps the block frame equal to the table size (origin fixed).
    func updatingTable(_ transform: (CanvasTable) throws -> CanvasTable) throws -> CanvasBlock {
        guard case .table(let table) = content else { throw DocumentError.invalid("Block is not a table") }
        let next = try transform(table)
        var block = self
        block.content = .table(next)
        block.layout.frame.width = next.width; block.layout.frame.height = next.height
        return block
    }
}
