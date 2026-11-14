#if canImport(UIKit)
// Adapted from Prumo PDF; see docs/licenses/Prumo-MIT.txt.
import PDFKit
import UIKit

/// Cores do marca-texto (as mesmas do Prumo para Windows).
enum HighlightColor: String, CaseIterable, Identifiable {
    case yellow, green, blue, pink, orange
    var id: String { rawValue }

    var label: String {
        switch self {
        case .yellow: return "Amarelo"
        case .green: return "Verde"
        case .blue: return "Azul"
        case .pink: return "Rosa"
        case .orange: return "Laranja"
        }
    }

    var rgb: (CGFloat, CGFloat, CGFloat) {
        switch self {
        case .yellow: return (1.0, 0.89, 0.25)
        case .green: return (0.56, 0.87, 0.42)
        case .blue: return (0.49, 0.76, 1.0)
        case .pink: return (1.0, 0.6, 0.8)
        case .orange: return (1.0, 0.7, 0.36)
        }
    }

    var uiColor: UIColor { UIColor(red: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1) }
}

/// Destaques gravados no próprio PDF, como anotações padrão de destaque (/Highlight): aparecem
/// no Prumo, no Adobe, no Edge, no Chrome e no Windows, e podem ser apagados em qualquer um deles.
enum Highlights {
    static let author = "Prumo PDF"

    /// Destaca a seleção: uma anotação por página, com um quadrilátero por linha.
    /// Devolve as anotações criadas (para desfazer).
    @discardableResult
    static func add(_ selection: PDFSelection, color: HighlightColor, in document: PDFDocument) -> [PDFAnnotation] {
        add(selection, uiColor: color.uiColor, in: document)
    }

    @discardableResult
    static func add(_ selection: PDFSelection, uiColor: UIColor, in document: PDFDocument) -> [PDFAnnotation] {
        var linesByPage: [Int: [(PDFPage, CGRect, String)]] = [:]
        for line in selection.selectionsByLine() {
            for page in line.pages {
                let r = line.bounds(for: page)
                guard r.width > 0.5, r.height > 0.5 else { continue }
                let i = document.index(for: page)
                linesByPage[i, default: []].append((page, r, line.string ?? ""))
            }
        }
        var added: [PDFAnnotation] = []
        for i in linesByPage.keys.sorted() {
            guard let lines = linesByPage[i], let page = lines.first?.0 else { continue }
            let rects = lines.map { $0.1.insetBy(dx: -0.8, dy: -0.8) }
            let bounds = rects.dropFirst().reduce(rects[0]) { $0.union($1) }
            let ann = PDFAnnotation(bounds: bounds, forType: .highlight, withProperties: nil)
            ann.color = uiColor
            ann.userName = author
            ann.contents = lines.map { $0.2 }.joined(separator: " ")
            ann.modificationDate = Date()
            _ = ann.setValue("prumo-hl-\(UUID().uuidString.prefix(16).lowercased())", forAnnotationKey: .name)
            // Quadriláteros relativos à origem da anotação: alto-esquerda, alto-direita, baixo-esquerda, baixo-direita.
            var quads: [NSValue] = []
            for r in rects {
                let x0 = r.minX - bounds.minX, x1 = r.maxX - bounds.minX
                let y0 = r.minY - bounds.minY, y1 = r.maxY - bounds.minY
                quads += [CGPoint(x: x0, y: y1), CGPoint(x: x1, y: y1), CGPoint(x: x0, y: y0), CGPoint(x: x1, y: y0)]
                    .map { NSValue(cgPoint: $0) }
            }
            ann.quadrilateralPoints = quads
            page.addAnnotation(ann)
            added.append(ann)
        }
        return added
    }

    static func isHighlight(_ a: PDFAnnotation) -> Bool {
        a.type == "Highlight" || a.type == PDFAnnotationSubtype.highlight.rawValue
            || a.type == "/Highlight"
    }

    /// O destaque que está no ponto (coordenadas da página), se houver.
    static func highlight(at point: CGPoint, on page: PDFPage) -> PDFAnnotation? {
        page.annotations.last { isHighlight($0) && $0.bounds.insetBy(dx: -2, dy: -2).contains(point) && covers($0, point) }
    }

    private static func covers(_ a: PDFAnnotation, _ p: CGPoint) -> Bool {
        let q = a.quadrilateralPoints?.map { $0.cgPointValue } ?? []
        guard q.count >= 4 else { return true }
        var k = 0
        while k + 3 < q.count {
            let xs = q[k..<k + 4].map(\.x), ys = q[k..<k + 4].map(\.y)
            let r = CGRect(x: (xs.min() ?? 0) + a.bounds.minX, y: (ys.min() ?? 0) + a.bounds.minY,
                           width: (xs.max() ?? 0) - (xs.min() ?? 0), height: (ys.max() ?? 0) - (ys.min() ?? 0))
            if r.insetBy(dx: -2, dy: -2).contains(p) { return true }
            k += 4
        }
        return false
    }

    static func name(_ a: PDFAnnotation) -> String? { a.value(forAnnotationKey: .name) as? String }

    /// O mesmo destaque na página (pelo nome /NM, que sobrevive a gravar e abrir de novo).
    static func find(_ a: PDFAnnotation, on page: PDFPage) -> PDFAnnotation? {
        if let n = name(a), !n.isEmpty {
            return page.annotations.first { isHighlight($0) && name($0) == n }
        }
        return page.annotations.first { $0 === a }
    }

    /// Retângulos das linhas do destaque, no espaço da página.
    static func lineRects(_ a: PDFAnnotation) -> [CGRect] {
        let q = a.quadrilateralPoints?.map { $0.cgPointValue } ?? []
        guard q.count >= 4 else { return [a.bounds] }
        var out: [CGRect] = []
        var k = 0
        while k + 3 < q.count {
            let xs = q[k..<k + 4].map(\.x), ys = q[k..<k + 4].map(\.y)
            out.append(CGRect(x: (xs.min() ?? 0) + a.bounds.minX, y: (ys.min() ?? 0) + a.bounds.minY,
                              width: (xs.max() ?? 0) - (xs.min() ?? 0), height: (ys.max() ?? 0) - (ys.min() ?? 0)))
            k += 4
        }
        return out
    }

    /// Caracteres da página (posições em `page.string`) cobertos pelo destaque.
    static func indices(of a: PDFAnnotation, on page: PDFPage) -> [Int] {
        var out = Set<Int>()
        for r in lineRects(a) {
            let band = r.insetBy(dx: 0.5, dy: r.height * 0.3)
            guard band.width > 0, band.height > 0, let sel = page.selection(for: band) else { continue }
            for k in 0..<sel.numberOfTextRanges(on: page) {
                let range = sel.range(at: k, on: page)
                if range.location != NSNotFound, range.length > 0 {
                    out.formUnion(range.location..<(range.location + range.length))
                }
            }
        }
        return out.sorted()
    }

    /// Posições soltas → trechos contínuos.
    static func runs(_ idx: [Int]) -> [NSRange] {
        var out: [NSRange] = []
        for k in Set(idx).sorted() {
            if let last = out.last, last.location + last.length == k {
                out[out.count - 1].length += 1
            } else {
                out.append(NSRange(location: k, length: 1))
            }
        }
        return out
    }

    /// Algum destaque cobre parte destes trechos?
    static func hasMarks(_ ranges: [(page: Int, range: NSRange)], in doc: PDFDocument) -> Bool {
        for (p, r) in ranges {
            guard let page = doc.page(at: p) else { continue }
            let sel = Set(r.location..<(r.location + r.length))
            for a in page.annotations where isHighlight(a) {
                if indices(of: a, on: page).contains(where: { sel.contains($0) }) { return true }
            }
        }
        return false
    }

    /// Tira o destaque só dos trechos escolhidos: o resto de cada destaque continua, com a mesma cor.
    static func unmark(_ ranges: [(page: Int, range: NSRange)], in doc: PDFDocument)
        -> (removed: [(Int, PDFAnnotation)], added: [(Int, PDFAnnotation)]) {
        var removed: [(Int, PDFAnnotation)] = []
        var added: [(Int, PDFAnnotation)] = []
        for (p, r) in ranges {
            guard let page = doc.page(at: p) else { continue }
            let sel = Set(r.location..<(r.location + r.length))
            for a in page.annotations where isHighlight(a) {
                let idx = indices(of: a, on: page)
                guard idx.contains(where: { sel.contains($0) }) else { continue }
                let color = a.color
                page.removeAnnotation(a)
                removed.append((p, a))
                for run in runs(idx.filter { !sel.contains($0) }) {
                    guard let s = page.selection(for: run),
                          !(s.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                    for n in add(s, uiColor: color, in: doc) { added.append((p, n)) }
                }
            }
        }
        return (removed, added)
    }

    /// Os trechos de uma seleção, por página: [(página, trecho em `page.string`)].
    static func ranges(of selection: PDFSelection, in doc: PDFDocument) -> [(page: Int, range: NSRange)] {
        var out: [(page: Int, range: NSRange)] = []
        for page in selection.pages {
            let p = doc.index(for: page)
            for k in 0..<selection.numberOfTextRanges(on: page) {
                let r = selection.range(at: k, on: page)
                if r.location != NSNotFound, r.length > 0 { out.append((p, r)) }
            }
        }
        return out
    }

    static func remove(_ a: PDFAnnotation) {
        a.page?.removeAnnotation(a)
    }

    static func recolor(_ a: PDFAnnotation, _ color: HighlightColor) {
        a.color = color.uiColor
        a.modificationDate = Date()
    }
}

#endif
