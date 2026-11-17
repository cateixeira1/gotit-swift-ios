#if canImport(UIKit)
import UIKit
import Vision
import CoreText
import PencilKit
import GotItDomain
import GotItCanvas

/// Fonts for writing turned into text: handwriting fonts under the SIL Open Font License that ship
/// with the app, plus fonts the user imports (.ttf/.otf), registered for this process only.
public enum HandwritingFonts {
    /// PostScript names of the bundled fonts, with the name shown to the user.
    public static let bundled: [(postScript: String, name: String)] = [
        ("Caveat-Regular", "Caveat"), ("PatrickHand-Regular", "Patrick Hand"),
        ("Kalam-Regular", "Kalam"), ("IndieFlower-Regular", "Indie Flower"),
    ]
    public static let defaultFont = "Caveat-Regular"

    /// Registers font files; returns the PostScript names that are now usable.
    @discardableResult
    public static func register(_ urls: [URL]) -> [String] {
        urls.compactMap { url in
            guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
                  let first = descriptors.first,
                  let name = CTFontDescriptorCopyAttribute(first, kCTFontNameAttribute) as? String else { return nil }
            if UIFont(name: name, size: 12) == nil {
                var error: Unmanaged<CFError>?
                CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
            }
            return UIFont(name: name, size: 12) == nil ? nil : name
        }
    }

    /// Display name of a font (its family), for menus.
    public static func displayName(_ postScript: String) -> String {
        bundled.first { $0.postScript == postScript }?.name ?? UIFont(name: postScript, size: 12)?.familyName ?? postScript
    }
}

/// Reading handwriting: the strokes are drawn again as clean black lines on white, sized for the
/// recognizer, and read with Vision's text recognition on the device (accurate level, the chosen
/// language first).
public enum HandwritingReader {
    public struct Reading: Sendable { public var text: String; public var confidence: Float; public var lines: Int }

    /// `correction` off for formulas: language correction turns "x2" or "1O" into words. With
    /// correction on, a reading that comes back unsure is compared with one without correction
    /// (block letters and names are often not dictionary words) and the surer one wins.
    public static func read(_ image: CGImage, languages: [String], correction: Bool = true) -> Reading? {
        let first = recognize(image, languages: languages, correction: correction)
        guard correction, (first?.confidence ?? 0) < 0.6 else { return first }
        let plain = recognize(image, languages: languages, correction: false)
        switch (first, plain) {
        case let (a?, b?): return b.confidence > a.confidence + 0.1 ? b : a
        default: return first ?? plain
        }
    }

    private static func recognize(_ image: CGImage, languages: [String], correction: Bool) -> Reading? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = correction
        request.recognitionLanguages = languages
        // The language is the user's; guessing it from a few handwritten words picks the wrong one.
        request.automaticallyDetectsLanguage = false
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up)
        guard (try? handler.perform([request])) != nil, let observations = request.results, !observations.isEmpty else { return nil }
        // Top to bottom (Vision's y grows upwards), left to right within a line.
        let ordered = observations.sorted { a, b in
            abs(a.boundingBox.midY - b.boundingBox.midY) > min(a.boundingBox.height, b.boundingBox.height) / 2
                ? a.boundingBox.midY > b.boundingBox.midY : a.boundingBox.minX < b.boundingBox.minX
        }
        let candidates = ordered.compactMap { $0.topCandidates(1).first }
        guard !candidates.isEmpty else { return nil }
        var lines: [String] = [], previous: VNRecognizedTextObservation?
        for (observation, candidate) in zip(ordered, candidates) {
            if let previous, abs(previous.boundingBox.midY - observation.boundingBox.midY) <= min(previous.boundingBox.height, observation.boundingBox.height) / 2 {
                lines[lines.count - 1] += " " + candidate.string
            } else { lines.append(candidate.string) }
            previous = observation
        }
        let confidence = candidates.map(\.confidence).reduce(0, +) / Float(candidates.count)
        return Reading(text: lines.joined(separator: "\n"), confidence: confidence, lines: lines.count)
    }

    /// How tall the letters are: the strokes' heights, ignoring dots, accents and crossbars (in
    /// block letters most strokes are a whole letter tall).
    static func letterHeight(_ heights: [CGFloat]) -> CGFloat {
        let sorted = heights.filter { $0.isFinite && $0 > 0 }.sorted()
        guard !sorted.isEmpty else { return 20 }
        return max(6, sorted[min(sorted.count - 1, sorted.count * 3 / 4)])
    }

    /// The strokes as a picture for the recognizer: black lines of even width on white, letters
    /// about 60 pixels tall, with room around them. The ink's own look (pencil grain, marker
    /// width, a thin pen) does not reach the recognizer.
    @MainActor public static func picture(of strokes: [PKStroke], bounds: CGRect) -> CGImage? {
        let letter = letterHeight(strokes.map(\.renderBounds.height))
        let margin = max(12, letter * 0.6)
        let area = bounds.insetBy(dx: -margin, dy: -margin)
        guard area.width > 0, area.height > 0 else { return nil }
        // Letters ~60 px tall, within 1.5…6 px per point and at most 4096 px across.
        let scale = min(6, max(1.5, 60 / letter), 4096 / max(area.width, area.height))
        let width = min(9, max(1.6, letter * 0.085))
        let format = UIGraphicsImageRendererFormat(); format.scale = scale; format.opaque = true
        return UIGraphicsImageRenderer(size: area.size, format: format).image { context in
            UIColor.white.setFill(); context.fill(CGRect(origin: .zero, size: area.size))
            UIColor.black.setStroke(); UIColor.black.setFill()
            for stroke in strokes {
                let points = stroke.path.interpolatedPoints(by: .distance(max(0.4, 1 / scale)))
                    .map { $0.location.applying(stroke.transform) }
                    .map { CGPoint(x: $0.x - area.minX, y: $0.y - area.minY) }
                guard let first = points.first else { continue }
                if points.count == 1 || points.allSatisfy({ hypot($0.x - first.x, $0.y - first.y) < width / 2 }) {
                    UIBezierPath(ovalIn: CGRect(x: first.x - width / 2, y: first.y - width / 2, width: width, height: width)).fill()
                    continue
                }
                let path = UIBezierPath()
                path.move(to: first)
                for point in points.dropFirst() { path.addLine(to: point) }
                path.lineWidth = width; path.lineCapStyle = .round; path.lineJoinStyle = .round
                path.stroke()
            }
        }.cgImage
    }

    /// Writing split into lines: strokes whose boxes overlap vertically by half and sit within a
    /// few letters of each other horizontally go on the same line.
    public static func lines(_ boxes: [CGRect]) -> [[Int]] {
        let order = boxes.indices.sorted { boxes[$0].midY < boxes[$1].midY }
        var lines: [(box: CGRect, members: [Int])] = []
        for index in order {
            let box = boxes[index]
            if let match = lines.indices.first(where: { line in
                let other = lines[line].box
                let overlap = min(other.maxY, box.maxY) - max(other.minY, box.minY)
                let gap = max(box.minX - other.maxX, other.minX - box.maxX)
                return overlap > 0.4 * min(other.height, box.height) && gap < 3 * max(other.height, box.height)
            }) {
                lines[match].box = lines[match].box.union(box); lines[match].members.append(index)
            } else { lines.append((box, [index])) }
        }
        // Lines close above each other (a paragraph) become one block.
        var blocks: [(box: CGRect, members: [Int])] = []
        for line in lines.sorted(by: { $0.box.minY < $1.box.minY }) {
            if let last = blocks.indices.last, line.box.minY - blocks[last].box.maxY < line.box.height * 0.8,
               abs(line.box.minX - blocks[last].box.minX) < line.box.height * 3 {
                blocks[last].box = blocks[last].box.union(line.box); blocks[last].members += line.members
            } else { blocks.append(line) }
        }
        return blocks.map(\.members)
    }
}
#endif
