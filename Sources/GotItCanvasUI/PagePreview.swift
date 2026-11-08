#if canImport(UIKit)
import UIKit
import PencilKit
import GotItDomain
import GotItCanvas

@MainActor
public enum PagePreview {
    /// Uses the same block renderer as the editor. Thumbnails represent actual page contents.
    public static func image(document: CanvasDocument, width: CGFloat = 120,
                             asset: (String) -> UIImage?, drawingData: (String) -> Data?) -> UIImage {
        let size = document.canvas.size
        let scale = width / max(1, size.width)
        let output = CGSize(width: width, height: max(1, size.height * scale))
        let frames = (try? CanvasLayoutEngine.frames(in: document)) ?? [:]
        return UIGraphicsImageRenderer(size: output).image { context in
            UIColor.white.setFill(); context.fill(CGRect(origin: .zero, size: output))
            context.cgContext.scaleBy(x: scale, y: scale)
            for block in document.blocks.sorted(by: { $0.layout.zIndex == $1.layout.zIndex ? $0.order < $1.order : $0.layout.zIndex < $1.layout.zIndex }) {
                guard let frame = frames[block.id] else { continue }
                let rect = CGRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height)
                context.cgContext.saveGState()
                context.cgContext.translateBy(x: rect.midX, y: rect.midY)
                context.cgContext.rotate(by: block.effectivePresentation.rotationRadians)
                context.cgContext.translateBy(x: -rect.width / 2, y: -rect.height / 2)
                if case .text(let text) = block.content {
                    let view = UITextView(usingTextLayoutManager: true)
                    view.frame = CGRect(origin: .zero, size: rect.size); view.backgroundColor = .clear
                    view.textContainerInset = UIEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
                    view.attributedText = TextBridge.attributed(text, base: (try? document.resolvedStyle(for: block.id)) ?? .init())
                    view.textContainer.exclusionPaths = ((try? TextFlowEngine.exclusions(for: block.id, in: document)) ?? []).map { exclusion in
                        let path = UIBezierPath()
                        for (index, point) in exclusion.polygon.enumerated() {
                            let p = CGPoint(x: point.x - 4, y: point.y - 4)
                            if index == 0 { path.move(to: p) } else { path.addLine(to: p) }
                        }
                        path.close(); return path
                    }
                    view.layoutIfNeeded()
                    view.layer.render(in: context.cgContext)
                } else if case .drawing(let ref) = block.content {
                    if let drawing = try? DrawingStorage.drawing(ref, data: drawingData) {
                        drawing.image(from: CGRect(origin: .zero, size: rect.size), scale: scale * 2).draw(in: CGRect(origin: .zero, size: rect.size))
                    }
                } else {
                    let view = CanvasObjectView(frame: CGRect(origin: .zero, size: rect.size))
                    view.block = block; view.asset = block.content.assetHash.flatMap(asset)
                    switch block.content {
                    case .sticker: context.cgContext.setShadow(offset: CGSize(width: 0, height: 4), blur: 5, color: UIColor.black.withAlphaComponent(0.24).cgColor)
                    case .shape(let shape) where shape.kind == .stickyNote || shape.kind == .calendar:
                        context.cgContext.setShadow(offset: CGSize(width: 0, height: 3), blur: 4, color: UIColor.black.withAlphaComponent(0.22).cgColor)
                    default: break
                    }
                    // One shadow for the whole object, not one per stroke of its drawing.
                    context.cgContext.beginTransparencyLayer(auxiliaryInfo: nil)
                    view.draw(view.bounds)
                    context.cgContext.endTransparencyLayer()
                }
                context.cgContext.restoreGState()
            }
            for relation in document.relations where relation.kind == .connector {
                guard let first = frames[relation.sourceID], let second = frames[relation.targetID] else { continue }
                let view = ConnectionView(frame: CGRect(x: 0, y: 0, width: size.width, height: size.height))
                view.relation = relation; view.points = ConnectorGeometry.path(from: first, to: second, routing: relation.style?.routing ?? .straight)
                view.draw(view.bounds)
            }
        }
    }
}
#endif
