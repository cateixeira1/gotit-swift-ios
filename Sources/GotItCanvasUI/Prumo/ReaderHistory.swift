#if canImport(UIKit)
// Adapted from Prumo PDF; see docs/licenses/Prumo-MIT.txt.
import Combine
import PDFKit
import UIKit

/// Desfazer e refazer do leitor: destaques (no documento aberto), cortar/girar e numerar
/// (o arquivo inteiro, antes e depois) e "adicionar ao resumo" (o resumo e a anotação dos trechos).
@MainActor
final class ReaderHistory: ObservableObject {
    enum Change {
        /// Destaques de um documento (`docID`): anotações tiradas e colocadas, com o número da página.
        case marks(docID: String, removed: [(Int, PDFAnnotation)], added: [(Int, PDFAnnotation)])
        case recolor(docID: String, page: Int, mark: PDFAnnotation, from: UIColor, to: UIColor)
        /// O arquivo inteiro de um PDF.
        case file(itemID: String, before: Data, after: Data)
        /// O resumo: o PDF (nil se ainda não existia) e a anotação dos trechos.
        case summary(summaryID: String?, rel: String, folder: String, name: String,
                     before: Data?, after: Data, storeBefore: Data?, storeAfter: Data?)
    }

    struct Step {
        let label: String
        var change: Change
    }

    @Published private(set) var undoSteps: [Step] = []
    @Published private(set) var redoSteps: [Step] = []
    static let limit = 30

    var canUndo: Bool { !undoSteps.isEmpty }
    var canRedo: Bool { !redoSteps.isEmpty }

    func record(_ label: String, _ change: Change) {
        undoSteps.append(Step(label: label, change: change))
        if undoSteps.count > Self.limit { undoSteps.removeFirst() }
        redoSteps.removeAll()
    }

    func popUndo() -> Step? { undoSteps.popLast() }
    func popRedo() -> Step? { redoSteps.popLast() }
    func pushRedo(_ s: Step) { redoSteps.append(s) }
    func pushUndo(_ s: Step) { undoSteps.append(s) }

    func clear() {
        undoSteps.removeAll()
        redoSteps.removeAll()
    }

    // MARK: aplicar destaques num documento

    /// Desfaz (`forward == false`) ou refaz uma mudança de destaques no documento.
    static func apply(_ change: Change, forward: Bool, in doc: PDFDocument) {
        switch change {
        case .marks(_, let removed, let added):
            let toRemove = forward ? removed : added
            let toAdd = forward ? added : removed
            for (p, a) in toRemove {
                guard let page = doc.page(at: p), let found = Highlights.find(a, on: page) else { continue }
                page.removeAnnotation(found)
            }
            for (p, a) in toAdd {
                guard let page = doc.page(at: p) else { continue }
                if Highlights.find(a, on: page) != nil { continue }
                let ann = a.page == nil ? a : ((a.copy() as? PDFAnnotation) ?? a)
                page.addAnnotation(ann)
            }
        case .recolor(_, let p, let mark, let from, let to):
            guard let page = doc.page(at: p), let found = Highlights.find(mark, on: page) else { return }
            found.color = forward ? to : from
        default:
            break
        }
    }
}

#endif
