import Foundation
import GotItDomain

/// An 8-bit RGBA bitmap (straight alpha), row-major from the top-left corner.
public struct RasterImage: Equatable, Sendable {
    public let width: Int
    public let height: Int
    public var rgba: [UInt8]
    public init(width: Int, height: Int, rgba: [UInt8]) {
        precondition(width > 0 && height > 0 && rgba.count == width * height * 4, "RGBA size mismatch")
        self.width = width; self.height = height; self.rgba = rgba
    }
    public func alpha(_ i: Int) -> UInt8 { rgba[i * 4 + 3] }
    /// Rec. 709 luma in 0...1; transparent pixels count as white (removed background).
    public func luminance(_ i: Int) -> Double {
        let a = Double(rgba[i * 4 + 3]) / 255
        let y = (0.2126 * Double(rgba[i * 4]) + 0.7152 * Double(rgba[i * 4 + 1]) + 0.0722 * Double(rgba[i * 4 + 2])) / 255
        return y * a + (1 - a)
    }
}

/// Background removal for drawings and writing on paper or a whiteboard, and the brush that
/// retouches a cut-out mask.
public enum PaperRemoval {
    /// Paper or whiteboard made transparent, the way scanner apps clean a photo of a page.
    ///
    /// A photo of paper is never evenly lit (shadow of the phone, a lamp on one side), so one
    /// global threshold leaves the darker part of the sheet as a grey smear. Instead the paper's
    /// own brightness is estimated around every point (a bright percentile per cell, spread to the
    /// neighbouring cells and smoothed) and each pixel is compared with the paper around it: ink
    /// is what is clearly darker than its local paper. `sensitivity` (0…1) moves that limit: higher
    /// keeps fainter marks (pencil), lower keeps only firm ones. Specks of a few pixels are dropped,
    /// and the ink is lit as if the paper were white, so a line keeps one colour across the shadow.
    public static func removingPaper(_ image: RasterImage, sensitivity: Double = 0.5) -> RasterImage {
        let w = image.width, h = image.height, count = w * h
        let luma = (0..<count).map { image.luminance($0) }
        let paper = paperBrightness(luma, width: w, height: h)
        let firm = 0.62 + 0.18 * min(1, max(0, sensitivity)), faint = firm + 0.12
        var keep = [Double](repeating: 0, count: count)
        for i in 0..<count where image.alpha(i) > 0 {
            let ratio = luma[i] / max(0.05, paper[i])
            keep[i] = min(1, max(0, (faint - ratio) / (faint - firm)))
        }
        // Specks: pieces of ink smaller than ~0.002% of the picture (at least 4 pixels).
        let minimum = max(4, count / 50_000)
        var seen = [Bool](repeating: false, count: count)
        for start in 0..<count where keep[start] > 0.5 && !seen[start] {
            var piece = [start], index = 0
            seen[start] = true
            while index < piece.count {
                let i = piece[index]; index += 1
                let x = i % w, y = i / w
                for dy in -1...1 { for dx in -1...1 where dx != 0 || dy != 0 {
                    let nx = x + dx, ny = y + dy
                    guard nx >= 0, ny >= 0, nx < w, ny < h else { continue }
                    let n = ny * w + nx
                    if keep[n] > 0.5, !seen[n] { seen[n] = true; piece.append(n) }
                } }
            }
            if piece.count < minimum { for i in piece { keep[i] = 0 } }
        }
        var output = image
        for i in 0..<count {
            output.rgba[i * 4 + 3] = UInt8((Double(image.alpha(i)) * keep[i]).rounded())
            guard keep[i] > 0 else { continue }
            let gain = 1 / max(0.3, paper[i])
            for c in 0..<3 { output.rgba[i * 4 + c] = UInt8(min(255, (Double(image.rgba[i * 4 + c]) * gain).rounded())) }
        }
        return output
    }

    /// Brightness of the paper around each pixel: 90th percentile of each cell (about 1/24 of the
    /// picture), the brightest of each cell and its neighbours (a cell full of ink takes its
    /// neighbours' paper), a blur, then bilinear interpolation between cell centres.
    static func paperBrightness(_ luma: [Double], width w: Int, height h: Int) -> [Double] {
        let cell = max(8, min(w, h) / 24)
        let gw = (w + cell - 1) / cell, gh = (h + cell - 1) / cell
        var grid = [Double](repeating: 1, count: gw * gh)
        for gy in 0..<gh { for gx in 0..<gw {
            var histogram = [Int](repeating: 0, count: 64), total = 0
            for y in (gy * cell)..<min(h, (gy + 1) * cell) { for x in (gx * cell)..<min(w, (gx + 1) * cell) {
                histogram[min(63, Int(luma[y * w + x] * 64))] += 1; total += 1
            } }
            var below = 0, bin = 0
            while bin < 63, Double(below + histogram[bin]) < 0.9 * Double(total) { below += histogram[bin]; bin += 1 }
            grid[gy * gw + gx] = (Double(bin) + 0.5) / 64
        } }
        func cellAt(_ gx: Int, _ gy: Int, in values: [Double]) -> Double { values[min(gh - 1, max(0, gy)) * gw + min(gw - 1, max(0, gx))] }
        var spread = grid
        for gy in 0..<gh { for gx in 0..<gw {
            var best = 0.0
            for dy in -1...1 { for dx in -1...1 { best = max(best, cellAt(gx + dx, gy + dy, in: grid)) } }
            spread[gy * gw + gx] = best
        } }
        var smooth = spread
        for gy in 0..<gh { for gx in 0..<gw {
            var sum = 0.0
            for dy in -1...1 { for dx in -1...1 { sum += cellAt(gx + dx, gy + dy, in: spread) } }
            smooth[gy * gw + gx] = sum / 9
        } }
        var result = [Double](repeating: 1, count: w * h)
        for y in 0..<h {
            let fy = (Double(y) + 0.5) / Double(cell) - 0.5
            let y0 = Int(fy.rounded(.down)), ty = fy - Double(y0)
            for x in 0..<w {
                let fx = (Double(x) + 0.5) / Double(cell) - 0.5
                let x0 = Int(fx.rounded(.down)), tx = fx - Double(x0)
                let top = cellAt(x0, y0, in: smooth) * (1 - tx) + cellAt(x0 + 1, y0, in: smooth) * tx
                let bottom = cellAt(x0, y0 + 1, in: smooth) * (1 - tx) + cellAt(x0 + 1, y0 + 1, in: smooth) * tx
                result[y * w + x] = top * (1 - ty) + bottom * ty
            }
        }
        return result
    }
}

/// Retouching brush for a cut-out: erases (makes transparent) or restores (brings back the
/// original picture) inside a round, soft-edged tip dragged along a path.
public enum MaskBrush {
    public enum Mode: Sendable { case erase, restore }

    /// Paints along `path` (pixel coordinates of the picture) on `mask` (alpha, one byte per pixel).
    /// `radius` in pixels; the outer 30% of the tip fades, so retouched edges stay smooth.
    /// Restoring never goes above `limit` (the original picture's own alpha), when given.
    public static func paint(_ mask: inout [UInt8], width w: Int, height h: Int, path: [CanvasPoint], radius: Double,
                             mode: Mode, limit: [UInt8]? = nil) {
        guard !path.isEmpty, radius > 0, mask.count == w * h else { return }
        // Dabs every third of the radius along the path, so a quick stroke has no gaps.
        var dabs = [path[0]]
        for (a, b) in zip(path, path.dropFirst()) {
            let length = hypot(b.x - a.x, b.y - a.y), steps = max(1, Int(ceil(length / max(0.5, radius / 3))))
            for step in 1...steps { let t = Double(step) / Double(steps); dabs.append(CanvasPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)) }
        }
        let hard = radius * 0.7
        // Strongest touch of the whole stroke per pixel (overlapping dabs do not stack up).
        let minX = max(0, Int(floor((dabs.map(\.x).min() ?? 0) - radius))), maxX = min(w - 1, Int(ceil((dabs.map(\.x).max() ?? 0) + radius)))
        let minY = max(0, Int(floor((dabs.map(\.y).min() ?? 0) - radius))), maxY = min(h - 1, Int(ceil((dabs.map(\.y).max() ?? 0) + radius)))
        guard minX <= maxX, minY <= maxY else { return }
        let bw = maxX - minX + 1
        var strength = [Double](repeating: 0, count: bw * (maxY - minY + 1))
        for dab in dabs {
            let x0 = max(minX, Int(floor(dab.x - radius))), x1 = min(maxX, Int(ceil(dab.x + radius)))
            let y0 = max(minY, Int(floor(dab.y - radius))), y1 = min(maxY, Int(ceil(dab.y + radius)))
            guard x0 <= x1, y0 <= y1 else { continue }
            for y in y0...y1 { for x in x0...x1 {
                let d = hypot(Double(x) + 0.5 - dab.x, Double(y) + 0.5 - dab.y)
                guard d < radius else { continue }
                let s = d <= hard ? 1 : (radius - d) / (radius - hard)
                let k = (y - minY) * bw + (x - minX)
                if s > strength[k] { strength[k] = s }
            } }
        }
        for y in minY...maxY { for x in minX...maxX {
            let s = strength[(y - minY) * bw + (x - minX)]
            guard s > 0 else { continue }
            let i = y * w + x, current = Double(mask[i])
            switch mode {
            case .erase: mask[i] = UInt8((current * (1 - s)).rounded())
            case .restore:
                let target = Double(limit?[i] ?? 255)
                mask[i] = UInt8(max(current, current + (target - current) * s).rounded())
            }
        } }
    }
}
