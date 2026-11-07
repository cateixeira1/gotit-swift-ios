import Foundation
import Testing
@testable import GotItDomain

private func tableBlock(rows: Int = 3, columns: Int = 3, width: Double = 300) -> CanvasBlock {
    let table = CanvasTable(rows: rows, columns: columns, width: width)
    return CanvasBlock(layout: .init(mode: .absolute, frame: .init(x: 20, y: 40, width: table.width, height: table.height)),
                       content: .table(table))
}

private func table(_ block: CanvasBlock) throws -> CanvasTable {
    guard case .table(let table) = block.content else { throw DocumentError.invalid("not a table") }
    return table
}

@Test func newTableHasAConsistentGridAndFrame() throws {
    let block = tableBlock()
    let grid = try table(block)
    #expect(grid.rowCount == 3 && grid.columnCount == 3)
    #expect(grid.width == 300 && grid.height == 108)
    _ = try CommandEngine.applying([.insertBlock(block)], to: CanvasDocument(title: "T"))
}

@Test func rowAndColumnEditsKeepFrameInSyncAndPreserveText() throws {
    var block = try tableBlock().updatingTable { try $0.settingText(RichText("B2"), row: 1, column: 1) }
    block = try block.updatingTable { try $0.insertingRow(at: 0) }
    #expect(try table(block).cells[2][1].text.plainText == "B2")      // shifted down
    block = try block.updatingTable { try $0.insertingColumn(at: 3) }
    #expect(try table(block).columnCount == 4)
    #expect(block.layout.frame.width == 400 && block.layout.frame.height == 144)
    block = try block.updatingTable { try $0.removingColumn(at: 0) }
    #expect(try table(block).cells[2][0].text.plainText == "B2")
    block = try block.updatingTable { try $0.removingRow(at: 0) }
    #expect(try table(block).cells[1][0].text.plainText == "B2")
    let final = try table(block)
    #expect(block.layout.frame.width == final.width && block.layout.frame.height == final.height)
    _ = try CommandEngine.applying([.insertBlock(block)], to: CanvasDocument(title: "T"))
}

@Test func lastRowAndColumnCannotBeRemovedAndIndicesAreChecked() throws {
    let single = try table(tableBlock(rows: 1, columns: 1))
    #expect(throws: DocumentError.self) { try single.removingRow(at: 0) }
    #expect(throws: DocumentError.self) { try single.removingColumn(at: 0) }
    #expect(throws: DocumentError.self) { try single.insertingRow(at: 5) }
    #expect(throws: DocumentError.self) { try single.settingText(RichText("x"), row: 0, column: 3) }
}

@Test func hitTestingMapsPointsToCells() throws {
    let grid = try table(tableBlock())   // 3 x 3, columns 100 wide, rows 36 tall
    #expect(grid.cell(at: .init(x: 5, y: 5))! == (0, 0))
    #expect(grid.cell(at: .init(x: 150, y: 40))! == (1, 1))
    #expect(grid.cell(at: .init(x: 300, y: 108))! == (2, 2))          // outer edge
    #expect(grid.cell(at: .init(x: 301, y: 5)) == nil)
    #expect(grid.frame(row: 2, column: 1) == LogicalRect(x: 100, y: 72, width: 100, height: 36))
}

@Test func rowsGrowToFitContentButNeverShrinkManualSizes() throws {
    let grid = try table(tableBlock())
    let taller = try grid.fittingRow(1, toContentHeight: 90)
    #expect(taller.rowHeights[1] == 90)
    #expect(try taller.fittingRow(1, toContentHeight: 10).rowHeights[1] == 90)
}

@Test func resizingScalesTheGridWithMinimums() throws {
    let grid = try table(tableBlock())
    let wider = grid.scaled(toWidth: 600, height: 216)
    #expect(wider.columnWidths == [200, 200, 200] && wider.rowHeights == [72, 72, 72])
    let tiny = grid.scaled(toWidth: 3, height: 3)
    #expect(tiny.columnWidths.allSatisfy { $0 == CanvasTable.minimumColumnWidth })
}

@Test func invalidTablesAreRejected() throws {
    let document = CanvasDocument(title: "T")
    var mismatched = tableBlock(); mismatched.layout.frame.width = 50
    #expect(throws: DocumentError.self) { try CommandEngine.applying([.insertBlock(mismatched)], to: document) }
    var ragged = tableBlock()
    if case .table(var grid) = ragged.content { grid.cells[0].removeLast(); ragged.content = .table(grid) }
    #expect(throws: DocumentError.self) { try CommandEngine.applying([.insertBlock(ragged)], to: document) }
    var badColor = tableBlock()
    if case .table(var grid) = badColor.content { grid.cells[0][0].background = "red"; badColor.content = .table(grid) }
    #expect(throws: DocumentError.self) { try CommandEngine.applying([.insertBlock(badColor)], to: document) }
}

@Test func tablePlainTextAndJSONRoundTrip() throws {
    var block = try tableBlock(rows: 2, columns: 2).updatingTable { try $0.settingText(RichText("Data"), row: 0, column: 0) }
    block = try block.updatingTable { try $0.settingText(RichText("Evento 👍🏽"), row: 0, column: 1) }
    #expect(try table(block).plainText == "Data\tEvento 👍🏽\n\t")
    #expect(try JSONDecoder().decode(CanvasBlock.self, from: JSONEncoder().encode(block)) == block)
}
