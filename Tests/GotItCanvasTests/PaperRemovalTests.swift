import Foundation
import Testing
import GotItDomain
@testable import GotItCanvas

/// A white (or transparent) canvas with dark paint where `ink` says so.
private func picture(_ width: Int, _ height: Int, paper: UInt8 = 255, alpha: UInt8 = 255, ink: (Double, Double) -> Bool) -> RasterImage {
    var rgba = [UInt8](repeating: 0, count: width * height * 4)
    for y in 0..<height { for x in 0..<width {
        let i = (y * width + x) * 4
        if ink(Double(x) + 0.5, Double(y) + 0.5) { rgba[i] = 20; rgba[i + 1] = 30; rgba[i + 2] = 140; rgba[i + 3] = 255 }
        else { rgba[i] = paper; rgba[i + 1] = paper; rgba[i + 2] = paper; rgba[i + 3] = alpha }
    } }
    return RasterImage(width: width, height: height, rgba: rgba)
}

@Test func paperBecomesTransparentAndInkStays() {
    // Slightly grey, noisy paper; a dark mark in the middle.
    var image = picture(64, 64, paper: 236) { x, y in abs(x - 32) < 6 && abs(y - 32) < 6 }
    for i in stride(from: 0, to: image.rgba.count, by: 4) where image.rgba[i] > 200 { image.rgba[i] = UInt8(226 + (i / 4) % 20) }
    let cleaned = PaperRemoval.removingPaper(image)
    #expect(cleaned.alpha(5 * 64 + 5) == 0)
    #expect(cleaned.alpha(32 * 64 + 32) == 255)
    #expect(abs(Int(cleaned.rgba[(32 * 64 + 32) * 4]) - 20) <= 3, "colour kept (lit as on white paper)")
}

@Test func unevenlyLitPaperGoesAwayEverywhereAndTheLinesStay() {
    // A sheet lit from the left: paper from 0.95 down to 0.45 on the right, where it is darker than
    // the ink on the left. Lines drawn at 40% of the paper's brightness around them.
    let w = 240, h = 160
    var rgba = [UInt8](repeating: 255, count: w * h * 4)
    func isLine(_ x: Int, _ y: Int) -> Bool { (y % 40 >= 18 && y % 40 <= 21 && x > 10 && x < w - 10) || (x % 60 >= 28 && x % 60 <= 30) }
    for y in 0..<h { for x in 0..<w {
        let paper = 0.95 - 0.5 * Double(x) / Double(w)
        let value = UInt8((255 * (isLine(x, y) ? 0.4 * paper : paper)).rounded())
        let i = (y * w + x) * 4
        rgba[i] = value; rgba[i + 1] = value; rgba[i + 2] = value
    } }
    // A few lone specks of dust.
    for (x, y) in [(5, 5), (100, 150), (200, 8)] { let i = (y * w + x) * 4; rgba[i] = 20; rgba[i + 1] = 20; rgba[i + 2] = 20 }
    let cleaned = PaperRemoval.removingPaper(RasterImage(width: w, height: h, rgba: rgba))
    var paperLeft = 0, linesLost = 0, lines = 0
    for y in 0..<h { for x in 0..<w {
        let a = cleaned.alpha(y * w + x)
        if isLine(x, y) { lines += 1; if a < 200 { linesLost += 1 } } else if a > 40 { paperLeft += 1 }
    } }
    #expect(paperLeft < w * h / 200, "paper left: \(paperLeft)")
    #expect(linesLost < lines / 50, "lines lost: \(linesLost) of \(lines)")
    #expect(cleaned.alpha(5 * w + 5) == 0 && cleaned.alpha(150 * w + 100) == 0, "specks go")
    // The same ink is about the same colour in the light and in the shadow.
    let left = Int(cleaned.rgba[(19 * w + 20) * 4]), right = Int(cleaned.rgba[(19 * w + 220) * 4])
    #expect(abs(left - right) < 30)
}

@Test func theBrushErasesAndRestoresInsideItsTip() {
    let w = 100, h = 60
    var mask = [UInt8](repeating: 255, count: w * h)
    MaskBrush.paint(&mask, width: w, height: h, path: [.init(x: 20, y: 30), .init(x: 80, y: 30)], radius: 6, mode: .erase)
    #expect(mask[30 * w + 50] == 0 && mask[30 * w + 20] == 0 && mask[30 * w + 80] == 0, "the whole stroke, no gaps")
    #expect(mask[10 * w + 50] == 255 && mask[30 * w + 5] == 255, "nothing outside the tip")
    let edge = mask[(30 + 5) * w + 50]
    #expect(edge > 0 && edge < 255, "soft edge: \(edge)")
    // Restoring brings back at most what the original picture had there.
    var limit = [UInt8](repeating: 255, count: w * h)
    limit[30 * w + 50] = 120
    MaskBrush.paint(&mask, width: w, height: h, path: [.init(x: 50, y: 30)], radius: 4, mode: .restore, limit: limit)
    #expect(mask[30 * w + 50] == 120 && mask[30 * w + 51] == 255)
    #expect(mask[30 * w + 70] == 0, "far from the tip stays erased")
    // A tip partly outside the picture is clipped, not a crash.
    MaskBrush.paint(&mask, width: w, height: h, path: [.init(x: -3, y: -3), .init(x: 2, y: 2)], radius: 10, mode: .erase)
    #expect(mask[0] == 0)
}
