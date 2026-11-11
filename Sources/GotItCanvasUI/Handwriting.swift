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

/// Reading handwriting: the strokes are drawn dark on white and read with Vision's text
/// recognition on the device (accurate level, language correction, the chosen language).
public enum HandwritingReader {
    public struct Reading: Sendable { public var text: String; public var confidence: Float; public var lines: Int }

    /// `correction` off for formulas: language correction turns "x2" or "1O" into words.
    public static func read(_ image: CGImage, languages: [String], correction: Bool = true) -> Reading? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = correction
        request.recognitionLanguages = languages
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

    /// The strokes as a picture: black ink on white, `scale` pixels per point, with a margin.
    @MainActor public static func picture(of strokes: [PKStroke], bounds: CGRect, scale: CGFloat = 3) -> CGImage? {
        let area = bounds.insetBy(dx: -12, dy: -12)
        let drawing = PKDrawing(strokes: strokes.map { stroke in
            var dark = stroke; dark.ink = PKInk(stroke.ink.inkType, color: .black); return dark
        })
        let format = UIGraphicsImageRendererFormat(); format.scale = scale; format.opaque = true
        let ink = drawing.image(from: area, scale: scale)
        return UIGraphicsImageRenderer(size: area.size, format: format).image { context in
            UIColor.white.setFill(); context.fill(CGRect(origin: .zero, size: area.size))
            ink.draw(in: CGRect(origin: .zero, size: area.size))
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
