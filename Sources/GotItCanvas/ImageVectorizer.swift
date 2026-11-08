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

/// A traced line: points along its middle (pixel coordinates, y down), its thickness and colour.
public struct TracedStroke: Equatable, Sendable {
    public var points: [CanvasPoint]
    public var width: Double
    public var color: String
    public var length: Double { zip(points, points.dropFirst()).reduce(0) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) } }
}

/// Turns a picture of lines (a sketch on paper, or a photo whose background was removed) into
/// editable strokes along the middle of each line, like the ones drawn with the pen: each line
/// becomes one stroke that can be erased, recoloured or moved, instead of an outline around it.
///
/// Steps: ink mask (dark against its surroundings) → distance to the nearest non-ink pixel
/// (thickness) → Zhang–Suen thinning to one-pixel centre lines → tracing of the centre-line graph
/// between ends and crossings → Douglas–Peucker simplification.
public enum ImageVectorizer {

    // MARK: Background of paper

    /// Paper or whiteboard background made transparent: luminance above the Otsu threshold
    /// between ink and paper fades out (soft edge of ±0.04 around it).
    public static func removingPaper(_ image: RasterImage) -> RasterImage {
        let count = image.width * image.height
        let luma = (0..<count).map { image.luminance($0) }
        let threshold = otsu(luma.indices.filter { image.alpha($0) > 0 }.map { luma[$0] })
        var output = image
        for i in 0..<count {
            let keep = min(1, max(0, (threshold + 0.04 - luma[i]) / 0.08))
            output.rgba[i * 4 + 3] = UInt8((Double(image.alpha(i)) * keep).rounded())
        }
        return output
    }

    /// Otsu's threshold of values in 0...1 (64 bins).
    static func otsu(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0.5 }
        var histogram = [Double](repeating: 0, count: 64)
        for v in values { histogram[min(63, max(0, Int(v * 64)))] += 1 }
        let total = Double(values.count)
        let sum = histogram.enumerated().reduce(0.0) { $0 + Double($1.offset) * $1.element }
        var scores = [Double](repeating: -1, count: 63), weight = 0.0, partial = 0.0
        for bin in 0..<63 {
            weight += histogram[bin]; partial += Double(bin) * histogram[bin]
            guard weight > 0, weight < total else { continue }
            let low = partial / weight, high = (sum - partial) / (total - weight)
            scores[bin] = weight * (total - weight) * (low - high) * (low - high)
        }
        // Two well separated groups give the same score for every empty bin between them: take
        // the middle of that plateau, not its first bin (which sits right on the darker group).
        guard let top = scores.max(), top > 0 else { return 0.5 }
        let best = scores.indices.filter { scores[$0] >= top * (1 - 1e-9) }
        return (Double(best[0] + best[best.count - 1]) / 2 + 1) / 64
    }

    // MARK: Ink

    /// Opaque pixels darker than their neighbourhood (local mean − 0.08), or simply dark (< 0.35).
    public static func inkMask(_ image: RasterImage) -> [Bool] {
        let w = image.width, h = image.height
        let luma = (0..<(w * h)).map { image.luminance($0) }
        // Integral image for the local mean.
        var integral = [Double](repeating: 0, count: (w + 1) * (h + 1))
        for y in 0..<h {
            var row = 0.0
            for x in 0..<w {
                row += luma[y * w + x]
                integral[(y + 1) * (w + 1) + x + 1] = integral[y * (w + 1) + x + 1] + row
            }
        }
        let r = max(4, min(w, h) / 24)
        var mask = [Bool](repeating: false, count: w * h)
        for y in 0..<h {
            let y0 = max(0, y - r), y1 = min(h, y + r + 1)
            for x in 0..<w {
                let i = y * w + x
                guard image.alpha(i) >= 128 else { continue }
                let x0 = max(0, x - r), x1 = min(w, x + r + 1)
                let area = Double((x1 - x0) * (y1 - y0))
                let sum = integral[y1 * (w + 1) + x1] - integral[y0 * (w + 1) + x1] - integral[y1 * (w + 1) + x0] + integral[y0 * (w + 1) + x0]
                mask[i] = luma[i] < 0.35 || luma[i] < sum / area - 0.08
            }
        }
        return mask
    }

    /// Chamfer (3-4) distance from each ink pixel to the nearest non-ink pixel, in pixels.
    static func distances(_ mask: [Bool], width w: Int, height h: Int) -> [Double] {
        let far = Int.max / 4
        var d = mask.map { $0 ? far : 0 }
        func at(_ x: Int, _ y: Int) -> Int { x < 0 || y < 0 || x >= w || y >= h ? 0 : d[y * w + x] }
        for y in 0..<h { for x in 0..<w where d[y * w + x] > 0 {
            d[y * w + x] = min(d[y * w + x], at(x - 1, y) + 3, at(x, y - 1) + 3, at(x - 1, y - 1) + 4, at(x + 1, y - 1) + 4)
        } }
        for y in stride(from: h - 1, through: 0, by: -1) { for x in stride(from: w - 1, through: 0, by: -1) where d[y * w + x] > 0 {
            d[y * w + x] = min(d[y * w + x], at(x + 1, y) + 3, at(x, y + 1) + 3, at(x + 1, y + 1) + 4, at(x - 1, y + 1) + 4)
        } }
        return d.map { Double($0) / 3 }
    }

    // MARK: Centre lines

    /// Zhang–Suen thinning, then removal of the staircase corners it leaves (so a slanted line is a
    /// simple chain of pixels and does not break into pieces at every step).
    static func thin(_ mask: [Bool], width w: Int, height h: Int) -> [Bool] {
        var m = mask
        func p(_ x: Int, _ y: Int) -> Bool { x >= 0 && y >= 0 && x < w && y < h && m[y * w + x] }
        /// Bit k is neighbour P(k+2) of Zhang–Suen: N, NE, E, SE, S, SW, W, NW.
        func bits(_ x: Int, _ y: Int) -> UInt8 {
            var b: UInt8 = 0
            if p(x, y - 1) { b |= 1 }; if p(x + 1, y - 1) { b |= 2 }; if p(x + 1, y) { b |= 4 }; if p(x + 1, y + 1) { b |= 8 }
            if p(x, y + 1) { b |= 16 }; if p(x - 1, y + 1) { b |= 32 }; if p(x - 1, y) { b |= 64 }; if p(x - 1, y - 1) { b |= 128 }
            return b
        }
        let north: UInt8 = 1, east: UInt8 = 4, south: UInt8 = 16, west: UInt8 = 64
        var active = m.indices.filter { m[$0] }
        var changed = true
        while changed {
            changed = false
            for pass in 0..<2 {
                var remove: [Int] = []
                for i in active where m[i] {
                    let n = bits(i % w, i / w)
                    let count = n.nonzeroBitCount
                    guard count >= 2, count <= 6 else { continue }
                    let next = (n >> 1) | (n << 7)                      // bit k = neighbour k+1
                    guard (~n & next).nonzeroBitCount == 1 else { continue }   // one 0→1 transition around
                    func all(_ mask: UInt8) -> Bool { n & mask == mask }
                    if pass == 0 { guard !all(north | east | south), !all(east | south | west) else { continue } }
                    else { guard !all(north | east | west), !all(north | south | west) else { continue } }
                    remove.append(i)
                }
                for i in remove { m[i] = false }
                if !remove.isEmpty { changed = true }
            }
            active = active.filter { m[$0] }
        }
        // Zhang–Suen leaves two-pixel "staircases" on slanted and curved lines. A pixel with two
        // or more 4-neighbours whose removal keeps its neighbours connected and opens no hole
        // (a simple point) is redundant there; ends of lines (one 4-neighbour at most) are kept.
        var again = true, rounds = 0
        while again, rounds < 4 {
            again = false; rounds += 1
            for i in active where m[i] {
                let n = bits(i % w, i / w)
                guard n.nonzeroBitCount >= 2, (n & 0x55).nonzeroBitCount >= 2, simplePoints[Int(n)] else { continue }
                m[i] = false; again = true
            }
        }
        return m
    }

    /// For each 8-neighbourhood (bit k = N, NE, E, SE, S, SW, W, NW): removing the centre keeps the
    /// neighbours in one 8-connected piece and the background around it in one 4-connected piece.
    static let simplePoints: [Bool] = (0..<256).map { value in
        let n = UInt8(value)
        func on(_ k: Int) -> Bool { n & (UInt8(1) << UInt8(k & 7)) != 0 }
        var seen: UInt8 = 0, foreground = 0
        for k in 0..<8 where on(k) && seen & (UInt8(1) << UInt8(k)) == 0 {
            foreground += 1; seen |= UInt8(1) << UInt8(k)
            var stack = [k]
            while let c = stack.popLast() {
                var adjacent = [(c + 1) % 8, (c + 7) % 8]
                if c % 2 == 0 { adjacent += [(c + 2) % 8, (c + 6) % 8] }   // N and E touch diagonally, etc.
                for a in adjacent where on(a) && seen & (UInt8(1) << UInt8(a)) == 0 { seen |= UInt8(1) << UInt8(a); stack.append(a) }
            }
        }
        var free: UInt8 = 0, background = 0
        for k in stride(from: 0, to: 8, by: 2) where !on(k) && free & (UInt8(1) << UInt8(k)) == 0 {
            background += 1; free |= UInt8(1) << UInt8(k)
            var stack = [k]
            while let c = stack.popLast() {
                for a in [(c + 1) % 8, (c + 7) % 8] where !on(a) && free & (UInt8(1) << UInt8(a)) == 0 { free |= UInt8(1) << UInt8(a); stack.append(a) }
            }
        }
        return foreground == 1 && background == 1
    }

    /// Polylines of the one-pixel skeleton: from each end or crossing to the next, plus closed loops
    /// and isolated dots.
    static func polylines(_ skeleton: [Bool], width w: Int, height h: Int) -> [[Int]] {
        func neighbours(_ i: Int) -> [Int] {
            let x = i % w, y = i / w
            var result: [Int] = []
            for dy in -1...1 { for dx in -1...1 where dx != 0 || dy != 0 {
                let nx = x + dx, ny = y + dy
                if nx >= 0, ny >= 0, nx < w, ny < h, skeleton[ny * w + nx] { result.append(ny * w + nx) }
            } }
            return result
        }
        let pixels = skeleton.indices.filter { skeleton[$0] }
        var degree: [Int: Int] = [:]
        for i in pixels { degree[i] = neighbours(i).count }
        func isNode(_ i: Int) -> Bool { degree[i] != 2 }
        var visitedEdges = Set<Int64>()
        func edge(_ a: Int, _ b: Int) -> Int64 { Int64(min(a, b)) * Int64(w * h) + Int64(max(a, b)) }
        var visited = Set<Int>()
        var lines: [[Int]] = []
        func walk(from start: Int, via first: Int) -> [Int] {
            var line = [start, first], previous = start, current = first
            visitedEdges.insert(edge(start, first)); visited.insert(start); visited.insert(first)
            while !isNode(current) {
                guard let next = neighbours(current).first(where: { $0 != previous && !visitedEdges.contains(edge(current, $0)) }) else { break }
                visitedEdges.insert(edge(current, next)); visited.insert(next)
                line.append(next); previous = current; current = next
                if next == start { break }
            }
            return line
        }
        for node in pixels where isNode(node) {
            let around = neighbours(node)
            if around.isEmpty { lines.append([node]); visited.insert(node); continue }
            for next in around where !visitedEdges.contains(edge(node, next)) { lines.append(walk(from: node, via: next)) }
        }
        // What is left are closed loops of degree-2 pixels.
        for start in pixels where !visited.contains(start) {
            guard let next = neighbours(start).first else { continue }
            var loop = walk(from: start, via: next)
            if loop.last != start { loop.append(start) }
            lines.append(loop)
        }
        return lines
    }

    /// Tracing stops at every crossing, so an X would be four strokes. Here the pieces meeting at a
    /// crossing are paired by direction (the straightest continuation, turning less than ~40°) and
    /// joined, so each drawn line comes back as one stroke. Tiny pieces inside a crossing go.
    static func joinedAtCrossings(_ lines: [[Int]], skeleton: [Bool], width w: Int, height h: Int) -> [[Int]] {
        func degree(_ i: Int) -> Int {
            let x = i % w, y = i / w
            var count = 0
            for dy in -1...1 { for dx in -1...1 where dx != 0 || dy != 0 {
                let nx = x + dx, ny = y + dy
                if nx >= 0, ny >= 0, nx < w, ny < h, skeleton[ny * w + nx] { count += 1 }
            } }
            return count
        }
        // Crossing pixels that touch form one crossing.
        var crossing: [Int: Int] = [:]
        for line in lines { for end in [line.first, line.last].compactMap({ $0 }) where crossing[end] == nil && degree(end) >= 3 {
            let id = crossing.count
            var stack = [end]; crossing[end] = id
            while let i = stack.popLast() {
                let x = i % w, y = i / w
                for dy in -1...1 { for dx in -1...1 where dx != 0 || dy != 0 {
                    let nx = x + dx, ny = y + dy, n = ny * w + nx
                    guard nx >= 0, ny >= 0, nx < w, ny < h, skeleton[n], crossing[n] == nil, degree(n) >= 3 else { continue }
                    crossing[n] = id; stack.append(n)
                } }
            }
        } }
        func point(_ i: Int) -> (Double, Double) { (Double(i % w), Double(i / w)) }
        var kept: [[Int]] = []
        for line in lines {
            // A short piece between two pixels of the same crossing is the crossing itself.
            if line.count <= 4, let a = line.first.flatMap({ crossing[$0] }), let b = line.last.flatMap({ crossing[$0] }), a == b { continue }
            kept.append(line)
        }
        struct End: Hashable { var line: Int; var atStart: Bool }
        var ends: [Int: [End]] = [:]
        for (index, line) in kept.enumerated() where line.count >= 2 && line.first != line.last {
            if let c = crossing[line[0]] { ends[c, default: []].append(End(line: index, atStart: true)) }
            if let c = crossing[line[line.count - 1]] { ends[c, default: []].append(End(line: index, atStart: false)) }
        }
        func direction(_ end: End) -> (Double, Double) {
            let line = kept[end.line], reach = min(line.count - 1, 8)
            let from = point(end.atStart ? line[0] : line[line.count - 1])
            let to = point(end.atStart ? line[reach] : line[line.count - 1 - reach])
            let dx = to.0 - from.0, dy = to.1 - from.1, length = max(1e-9, hypot(dx, dy))
            return (dx / length, dy / length)
        }
        var partner: [End: End] = [:]
        for (_, here) in ends where here.count >= 2 {
            var pairs: [(Double, End, End)] = []
            for i in here.indices { for j in here.indices where j > i && here[i].line != here[j].line {
                let a = direction(here[i]), b = direction(here[j])
                pairs.append((a.0 * b.0 + a.1 * b.1, here[i], here[j]))
            } }
            for (dot, a, b) in pairs.sorted(by: { $0.0 < $1.0 }) where dot < -0.75 && partner[a] == nil && partner[b] == nil {
                partner[a] = b; partner[b] = a
            }
        }
        // Walk the chains: from a piece, follow its links in both directions.
        var used = [Bool](repeating: false, count: kept.count)
        var result: [[Int]] = []
        for start in kept.indices where !used[start] {
            // Go back to the first piece of the chain (or around a loop of pieces).
            var first = End(line: start, atStart: true), steps = 0
            while let previous = partner[first], previous.line != start, steps < kept.count {
                first = End(line: previous.line, atStart: !previous.atStart); steps += 1
            }
            var chain: [Int] = [], current: End? = first
            while let piece = current, !used[piece.line] {
                used[piece.line] = true
                let pixels = piece.atStart ? kept[piece.line] : kept[piece.line].reversed()
                chain += chain.last == pixels.first ? Array(pixels.dropFirst()) : pixels
                current = partner[End(line: piece.line, atStart: !piece.atStart)].map { End(line: $0.line, atStart: $0.atStart) }
            }
            result.append(chain)
        }
        return result
    }

    /// Douglas–Peucker on a polyline; keeps both ends.
    static func simplify(_ points: [CanvasPoint], tolerance: Double) -> [CanvasPoint] {
        guard points.count > 2 else { return points }
        var keep = [Bool](repeating: false, count: points.count)
        keep[0] = true; keep[points.count - 1] = true
        var stack = [(0, points.count - 1)]
        while let range = stack.popLast() {
            let (a, b) = range
            guard b > a + 1 else { continue }
            let p = points[a], q = points[b]
            let dx = q.x - p.x, dy = q.y - p.y, length = max(hypot(dx, dy), 1e-9)
            var worst = (distance: -1.0, index: a)
            for i in (a + 1)..<b {
                let r = points[i]
                // Distance to the chord; for a closed loop (p == q) the distance to p.
                let distance = hypot(dx, dy) < 1e-9 ? hypot(r.x - p.x, r.y - p.y) : abs(dy * (r.x - p.x) - dx * (r.y - p.y)) / length
                if distance > worst.distance { worst = (distance, i) }
            }
            if worst.distance > tolerance { keep[worst.index] = true; stack.append((a, worst.index)); stack.append((worst.index, b)) }
        }
        return points.indices.filter { keep[$0] }.map { points[$0] }
    }

    // MARK: Strokes

    /// Centre-line strokes of the ink in `image`. Pieces shorter than `minimumLength` pixels are
    /// dropped (noise, the stubs thinning leaves at line ends) unless they are a real dot.
    public static func trace(_ image: RasterImage, minimumLength: Double = 3, maximumStrokes: Int = 4000) -> [TracedStroke] {
        let w = image.width, h = image.height
        let mask = inkMask(image)
        let distance = distances(mask, width: w, height: h)
        var skeleton = thin(mask, width: w, height: h)
        // Thinning can erase a small blob (a 2×2 dot) entirely: give it back its deepest pixel.
        var seen = [Bool](repeating: false, count: w * h)
        for start in mask.indices where mask[start] && !seen[start] {
            var stack = [start], deepest = start, kept = false
            seen[start] = true
            while let i = stack.popLast() {
                if skeleton[i] { kept = true }
                if distance[i] > distance[deepest] { deepest = i }
                let x = i % w, y = i / w
                for dy in -1...1 { for dx in -1...1 where dx != 0 || dy != 0 {
                    let nx = x + dx, ny = y + dy
                    guard nx >= 0, ny >= 0, nx < w, ny < h, mask[ny * w + nx], !seen[ny * w + nx] else { continue }
                    seen[ny * w + nx] = true; stack.append(ny * w + nx)
                } }
            }
            if !kept { skeleton[deepest] = true }
        }
        var strokes: [TracedStroke] = []
        for line in joinedAtCrossings(polylines(skeleton, width: w, height: h), skeleton: skeleton, width: w, height: h) {
            let points = line.map { CanvasPoint(x: Double($0 % w) + 0.5, y: Double($0 / w) + 0.5) }
            let thickness = line.map { distance[$0] }.sorted()
            let width = min(40, max(1, 2 * thickness[thickness.count / 2] - 0.5))
            let stroke = TracedStroke(points: simplify(points, tolerance: 0.9), width: width, color: averageColor(image, line))
            let body = (thickness.last ?? 0) >= 1.5
            if line.count == 1 || stroke.length < minimumLength {
                // Short: a thinning spur on a longer line is dropped; a real dot (with some body) stays.
                guard body, line.count == 1 || !isStub(line, skeleton: skeleton, width: w, height: h) else { continue }
                var dot = stroke; dot.points = [points[points.count / 2], points[points.count / 2]]
                strokes.append(dot)
            } else { strokes.append(stroke) }
            if strokes.count >= maximumStrokes { break }
        }
        return strokes
    }

    /// A short piece attached to a longer line at one end (a thinning spur), not a dot on its own.
    private static func isStub(_ line: [Int], skeleton: [Bool], width w: Int, height h: Int) -> Bool {
        func degree(_ i: Int) -> Int {
            let x = i % w, y = i / w
            var count = 0
            for dy in -1...1 { for dx in -1...1 where dx != 0 || dy != 0 {
                let nx = x + dx, ny = y + dy
                if nx >= 0, ny >= 0, nx < w, ny < h, skeleton[ny * w + nx] { count += 1 }
            } }
            return count
        }
        guard let first = line.first, let last = line.last else { return false }
        return degree(first) >= 3 || degree(last) >= 3
    }

    private static func averageColor(_ image: RasterImage, _ pixels: [Int]) -> String {
        var r = 0.0, g = 0.0, b = 0.0, n = 0.0
        for i in pixels where image.alpha(i) > 0 {
            r += Double(image.rgba[i * 4]); g += Double(image.rgba[i * 4 + 1]); b += Double(image.rgba[i * 4 + 2]); n += 1
        }
        guard n > 0 else { return "#000000" }
        return String(format: "#%02X%02X%02X", Int((r / n).rounded()), Int((g / n).rounded()), Int((b / n).rounded()))
    }
}
