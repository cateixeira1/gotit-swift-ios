#if canImport(UIKit)
import Foundation
import PencilKit
import GotItDomain

/// How the editor hands a drawing to the host after a gesture.
public enum DrawingSave: Sendable {
    /// The whole drawing (strokes were erased, moved or converted, or there were too many parts).
    case full(Data)
    /// Only the strokes added since the last save, to be laid over the saved drawing.
    case appended(Data)
    /// The drawing did not change; only the accompanying commands matter.
    case unchanged
}

public enum DrawingStorage {
    /// The saved drawing: the base asset with its parts laid over it, in order.
    public static func drawing(_ reference: AssetReference, data: (String) -> Data?) throws -> PKDrawing {
        var drawing = PKDrawing()
        for hash in reference.allHashes {
            guard let bytes = data(hash) else { throw DocumentError.invalid("Desenho indisponível") }
            drawing.append(try PKDrawing(data: bytes))
        }
        return drawing
    }

    /// Identifies a stroke and its current form: creation time, number of points and where it is
    /// drawn (a stroke moved, resized or cut by the eraser gets another fingerprint).
    public static func fingerprint(_ stroke: PKStroke) -> String {
        let box = stroke.renderBounds
        return "\(stroke.path.creationDate.timeIntervalSinceReferenceDate)|\(stroke.path.count)|\(box.origin.x),\(box.origin.y),\(box.size.width),\(box.size.height)"
    }
}
#endif
