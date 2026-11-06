import Foundation
import Testing
import GotItDomain
@testable import GotItCanvas

@Test func a4AndCustomUnitsRoundTrip() throws {
    let cm = try CanvasSize.a4.dimensions(in: .centimeters)
    #expect(abs(cm.width - 21) < 0.000001)
    #expect(abs(cm.height - 29.7) < 0.000001)
    let px = try CanvasSize(width: 960, height: 480, unit: .pixels)
    #expect(px.width == 720)
    #expect(try px.dimensions(in: .inches).height == 5)
    #expect(throws: DocumentError.self) { try CanvasSize(width: -1, height: 1, unit: .inches) }
    #expect(throws: DocumentError.self) { try CanvasSize(width: 1, height: 1, unit: .pixels, pixelsPerInch: 0) }
}

@Test func zoomDoesNotChangeDocumentGeometry() throws {
    let viewport = try CanvasViewport(zoom: 2.5, offset: .init(x: 120, y: 80))
    let point = CanvasPoint(x: 30, y: 15)
    #expect(viewport.canvasPoint(from: viewport.screenPoint(from: point)) == point)
}

@Test func flowAbsoluteAndAnchoredPositionsResolve() throws {
    var document = CanvasDocument(title: "Layout")
    let first = CanvasBlock(layout: .init(frame: .init(x: 10, y: 10, width: 100, height: 60)), content: .container)
    let next = CanvasBlock(order: 1, layout: .init(frame: .init(x: 10, y: 8, width: 100, height: 40)), content: .container)
    let child = CanvasBlock(parentID: first.id, layout: .init(mode: .absolute, frame: .init(x: 5, y: 6)), content: .text(.init("A")))
    let anchor = CanvasBlock(order: 2, layout: .init(mode: .anchored, frame: .init(x: 120, y: 0), anchorID: first.id), content: .container)
    document.blocks = [child, next, anchor, first]
    let frames = try CanvasLayoutEngine.frames(in: document)
    #expect(frames[next.id]?.y == 78)
    #expect(frames[child.id]?.x == 15)
    #expect(frames[child.id]?.y == 16)
    #expect(frames[anchor.id]?.x == 130)
}

@Test func rejectsImplicitFlowAnchorCycles() {
    var document = CanvasDocument(title: "Cycle")
    var first = CanvasBlock(content: .container)
    let second = CanvasBlock(order: 1, content: .container)
    let anchoredParent = CanvasBlock(order: 2, layout: .init(mode: .anchored, anchorID: second.id), content: .container)
    first.parentID = anchoredParent.id
    // Explicit cycle with parent/anchor is rejected at the command boundary.
    var secondCopy = second; secondCopy.parentID = first.id
    document.blocks = [first, secondCopy, anchoredParent]
    #expect(throws: DocumentError.self) { try CanvasLayoutEngine.frames(in: document) }
}

@Test func textExclusionsRespectDefaultsOverridesAndRotation() throws {
    var document = CanvasDocument(title: "Wrap")
    let text = CanvasBlock(layout: .init(mode: .absolute, frame: .init(x: 20, y: 20, width: 500, height: 700)), content: .text(.init("Text")))
    var shape = CanvasBlock(order: 1, layout: .init(mode: .absolute, frame: .init(x: 100, y: 100, width: 80, height: 40)), content: .shape(.init(kind: .rectangle)), presentation: .init(textPadding: 0, rotationRadians: .pi / 2))
    document.blocks = [text, shape]
    let paths = try TextFlowEngine.exclusions(for: text.id, in: document)
    #expect(paths.count == 1)
    #expect(abs(paths[0].polygon[0].x - 100) < 0.000001)
    document.canvas.textAvoidsObjects = false
    #expect(try TextFlowEngine.exclusions(for: text.id, in: document).isEmpty)
    shape.presentation?.wrap = .bounds
    document.blocks[1] = shape
    #expect(try TextFlowEngine.exclusions(for: text.id, in: document).count == 1)
}

@Test func shapeParentDoesNotExcludeItsOwnText() throws {
    let original = CanvasDocument(title: "Node")
    let doc = try CommandEngine.applying(DiagramCommands.insertNode(kind: .rectangle, frame: .init(width: 180, height: 100), order: 0), to: original)
    #expect(doc.blocks.count == 2)
    #expect(try TextFlowEngine.exclusions(for: doc.blocks[1].id, in: doc).isEmpty)
}

@Test func connectorEndpointsFollowNodes() {
    let source = LogicalRect(x: 0, y: 0, width: 100, height: 100)
    let target = LogicalRect(x: 300, y: 0, width: 100, height: 100)
    #expect(ConnectorGeometry.path(from: source, to: target) == [.init(x: 100, y: 50), .init(x: 300, y: 50)])
    #expect(ConnectorGeometry.path(from: source, to: target, routing: .orthogonal).count == 4)
}

@Test func resizingShapeKeepsChildGeometryProportional() throws {
    var doc = CanvasDocument(title: "Resize")
    doc = try CommandEngine.applying(DiagramCommands.insertNode(kind: .rectangle, frame: .init(width: 200, height: 100), order: 0), to: doc)
    let before = doc.blocks[1].layout.frame
    let commands = try CanvasTransforms.resize(doc.blocks[0].id, width: 400, height: 200, in: doc)
    let resized = try CommandEngine.applying(commands, to: doc)
    #expect(resized.blocks[1].layout.frame.width == before.width * 2)
    #expect(resized.blocks[1].layout.frame.x == before.x * 2)
}

private func rectangleStroke() -> [CanvasPoint] {
    let corners = [CanvasPoint(x: 10, y: 20), .init(x: 210, y: 20), .init(x: 210, y: 120), .init(x: 10, y: 120), .init(x: 10, y: 20)]
    return (0..<4).flatMap { i in (0..<12).map { step in
        let t = Double(step) / 11
        return CanvasPoint(x: corners[i].x + (corners[i + 1].x - corners[i].x) * t, y: corners[i].y + (corners[i + 1].y - corners[i].y) * t)
    } }
}

@Test func recognitionPreservesProportionsAndOriginalStroke() throws {
    let points = rectangleStroke()
    let shape = try #require(DiagramRecognizer.recognize(points))
    #expect(shape.kind == .rectangle)
    #expect(shape.frame.width / shape.frame.height == 2)
    let doc = try CommandEngine.applying(DiagramCommands.insertStroke(points, in: .init(title: "D")), to: .init(title: "D"))
    if case .shape(let shape) = doc.blocks[0].content { #expect(shape.originalStroke?.points.count == points.count) }
    else { Issue.record("Expected a recognized shape") }
    #expect(doc.blocks[1].parentID == doc.blocks[0].id)
}

@Test func recognitionCanBeDisabledWithoutLosingInk() throws {
    var document = CanvasDocument(title: "Manual")
    document.canvas.recognizeDiagrams = false
    let result = try CommandEngine.applying(DiagramCommands.insertStroke(rectangleStroke(), in: document), to: document)
    #expect(result.blocks.count == 1)
    if case .ink(let ink) = result.blocks[0].content { #expect(ink.points.count == rectangleStroke().count) }
    else { Issue.record("Expected original ink") }
}

@Test func equationsLinearQuadraticAndDegenerate() throws {
    #expect(try EquationSolver.solve("2x + 4 = 0") == .realRoots([-2]))
    let quadratic = try EquationSolver.solve("x² - 5x + 6 = 0")
    if case .realRoots(let roots) = quadratic { #expect(abs(roots[0] - 2) < 1e-12); #expect(abs(roots[1] - 3) < 1e-12) }
    else { Issue.record("Expected two roots") }
    #expect(try EquationSolver.solve("x^2 + 2x + 1 = 0") == .realRoots([-1]))
    #expect(try EquationSolver.solve("x^2 + 1 = 0") == .noRealRoots)
    #expect(try EquationSolver.solve("0x = 0") == .allRealNumbers)
    #expect(try EquationSolver.solve("0 = 1") == .noRealRoots)
    #expect(try EquationSolver.solve("0,5x = 2") == .realRoots([4]))
}

@Test(arguments: ["x^3=0", "2xy=1", "sin(x)=0", "x+=0", "*x=0", "x=", "=0", "x=1=2", "(x+1)^2=0"])
func unsupportedMathRequiresCorrection(_ expression: String) {
    #expect(throws: DocumentError.self) { try EquationSolver.solve(expression) }
}

@Test func quadraticSolverAvoidsCancellation() throws {
    guard case .realRoots(let roots) = try EquationSolver.solve(.init(a: 1, b: 1e8, c: 1)) else { Issue.record("Expected roots"); return }
    #expect(abs(roots[0] + 1e8) < 1e-6)
    #expect(abs(roots[1] + 1e-8) < 1e-20)
    #expect(try EquationSolver.solve(.init(a: 1, b: 1e-200, c: 0)) == .realRoots([-1e-200, 0]))
    #expect(throws: DocumentError.self) { try EquationSolver.solve(.init(a: 1e308, b: 0, c: -1e-308)) }
}

@Test func teiaReferencesChronologyAndPositionsAreIndependent() throws {
    let first = NoteCardMetadata(id: UUID(), title: "First", createdAt: Date(timeIntervalSince1970: 1))
    let second = NoteCardMetadata(id: UUID(), title: "Second", createdAt: Date(timeIntervalSince1970: 2))
    var web = CanvasDocument(title: "Teia", kind: .web)
    web = try CommandEngine.applying(TeiaEngine.addNotes([second, first, first], to: web), to: web)
    #expect(web.blocks.count == 2)
    let metadata = [first.id: first, second.id: second]
    let chronology = TeiaEngine.chronology(in: web, metadata: metadata)
    web.blocks[0].layout.frame.x = 500
    web.blocks[1].layout.frame.x = 0
    #expect(TeiaEngine.chronology(in: web, metadata: metadata) == chronology)
    #expect(try TeiaEngine.addNotes([first], to: web).isEmpty)
    #expect(TeiaEngine.chronology(in: web, metadata: [:]).isEmpty)
}

@Test func oldDocumentPayloadReceivesDefaults() throws {
    let original = CanvasDocument(title: "Legacy")
    var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
    json.removeValue(forKey: "canvas"); json.removeValue(forKey: "kind")
    let decoded = try JSONDecoder().decode(CanvasDocument.self, from: JSONSerialization.data(withJSONObject: json))
    #expect(decoded.canvas == CanvasSettings())
    #expect(decoded.kind == .note)
}

@Test func invalidCropAndNoteReferenceAreRejected() {
    var doc = CanvasDocument(title: "Bad")
    doc.blocks = [CanvasBlock(content: .noteReference(.init(documentID: UUID())))]
    #expect(throws: DocumentError.self) { try DocumentValidator.validate(doc) }
    doc.blocks = [CanvasBlock(content: .container, presentation: .init(imageCrop: .init(x: 0, y: 0, width: 1, height: 1)))]
    #expect(throws: DocumentError.self) { try DocumentValidator.validate(doc) }
}

@Test func cullingIncludesRotatedObjects() throws {
    var doc = CanvasDocument(title: "Viewport")
    let shape = CanvasBlock(layout: .init(mode: .absolute, frame: .init(x: 100, y: 100, width: 100, height: 20)), content: .shape(.init(kind: .rectangle)), presentation: .init(rotationRadians: .pi / 2))
    doc.blocks = [shape]
    #expect(try CanvasLayoutEngine.visibleBlocks(in: doc, viewport: .init(x: 145, y: 65, width: 10, height: 10), overscan: 0) == [shape.id])
}

@Test func pageFlowAndTextWrappingAreIsolated() throws {
    var document = CanvasDocument(title: "Pages")
    let second = CanvasPage(title: "Second"); document.pages.append(second)
    let text = CanvasBlock(layout: .init(frame: .init(x: 0, y: 0, width: 300, height: 300)), content: .text(.init("First page")))
    let shape = CanvasBlock(order: 1, layout: .init(frame: .init(x: 20, y: 10, width: 100, height: 100)), content: .shape(.init(kind: .rectangle)), pageID: second.id)
    document.blocks = [text, shape]
    let frames = try CanvasLayoutEngine.frames(in: document)
    #expect(frames[shape.id]?.y == 10)
    #expect(try TextFlowEngine.exclusions(for: text.id, in: document).isEmpty)
}
