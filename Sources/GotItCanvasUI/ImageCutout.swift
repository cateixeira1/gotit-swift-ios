#if canImport(UIKit)
import UIKit
import Vision
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import PencilKit
import GotItDomain
import GotItCanvas

/// Background removal and vectorisation of a picture on the page.
///
/// - Photos (a person, an object, an animal): Vision's subject lifting
///   (`VNGenerateForegroundInstanceMaskRequest`, iOS 17) keeps the subjects and clears the rest.
/// - Drawings and writing on paper or a whiteboard: the light paper is made transparent
///   (`ImageVectorizer.removingPaper`); subject lifting is not made for line drawings.
///   This is also the fallback when Vision finds no subject or cannot run (the simulator).
///
/// Vectorising traces the lines of the cut-out into pen strokes along their middle
/// (`ImageVectorizer.trace`), which then behave like strokes drawn on the page.
enum ImageCutout {
    enum Method: Sendable { case subject, paper }

    struct Cutout: Sendable {
        var image: RasterImage
        var method: Method
    }

    /// Upright (orientation applied) RGBA copy of `image`, at most `maxSide` pixels on its longest side.
    @MainActor static func raster(_ image: UIImage, maxSide: CGFloat) -> RasterImage? {
        guard image.size.width > 0, image.size.height > 0 else { return nil }
        let scale = min(1, maxSide / max(image.size.width * image.scale, image.size.height * image.scale))
        let width = max(1, Int((image.size.width * image.scale * scale).rounded()))
        let height = max(1, Int((image.size.height * image.scale * scale).rounded()))
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn: Bool = bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            UIGraphicsPushContext(context)
            context.translateBy(x: 0, y: CGFloat(height)); context.scaleBy(x: 1, y: -1)
            image.draw(in: CGRect(x: 0, y: 0, width: width, height: height))
            UIGraphicsPopContext()
            return true
        }
        guard drawn else { return nil }
        return RasterImage(width: width, height: height, rgba: unpremultiplied(bytes))
    }

    static func unpremultiplied(_ bytes: [UInt8]) -> [UInt8] {
        var out = bytes
        for i in stride(from: 0, to: out.count, by: 4) {
            let a = Int(out[i + 3])
            guard a > 0, a < 255 else { continue }
            for c in 0..<3 { out[i + c] = UInt8(min(255, (Int(out[i + c]) * 255 + a / 2) / a)) }
        }
        return out
    }

    static func cgImage(_ raster: RasterImage) -> CGImage? {
        var premultiplied = raster.rgba
        for i in stride(from: 0, to: premultiplied.count, by: 4) {
            let a = Int(premultiplied[i + 3])
            for c in 0..<3 { premultiplied[i + c] = UInt8((Int(premultiplied[i + c]) * a + 127) / 255) }
        }
        guard let provider = CGDataProvider(data: Data(premultiplied) as CFData) else { return nil }
        return CGImage(width: raster.width, height: raster.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: raster.width * 4,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    static func raster(_ image: CGImage) -> RasterImage? {
        let width = image.width, height = image.height
        guard width > 0, height > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn: Bool = bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? RasterImage(width: width, height: height, rgba: unpremultiplied(bytes)) : nil
    }

    /// A light, nearly colourless background covering most of the picture: paper or a whiteboard.
    static func looksLikePaper(_ image: RasterImage) -> Bool {
        let count = image.width * image.height
        var light = 0, grey = 0
        for i in 0..<count {
            let r = Double(image.rgba[i * 4]), g = Double(image.rgba[i * 4 + 1]), b = Double(image.rgba[i * 4 + 2])
            let high = max(r, g, b), low = min(r, g, b)
            guard high > 150 else { continue }
            light += 1
            if (high - low) / high < 0.18 { grey += 1 }
        }
        return Double(light) > 0.55 * Double(count) && Double(grey) > 0.8 * Double(light)
    }

    /// Vision subject lifting; nil when there is no subject or Vision cannot run here.
    static func liftSubject(_ image: RasterImage) -> RasterImage? {
        guard let cg = cgImage(image) else { return nil }
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: cg, orientation: .up)
        do {
            try handler.perform([request])
            guard let result = request.results?.first, !result.allInstances.isEmpty else { return nil }
            let buffer = try result.generateMaskedImage(ofInstances: result.allInstances, from: handler, croppedToInstancesExtent: false)
            let masked = CIImage(cvPixelBuffer: buffer)
            guard let output = CIContext().createCGImage(masked, from: masked.extent) else { return nil }
            return raster(output)
        } catch { return nil }
    }

    /// Runs off the main thread.
    static func removeBackground(_ image: RasterImage) -> Cutout {
        if !looksLikePaper(image), let subject = liftSubject(image) { return Cutout(image: subject, method: .subject) }
        return Cutout(image: ImageVectorizer.removingPaper(image), method: .paper)
    }

    static func png(_ image: RasterImage) -> Data? {
        guard let cg = cgImage(image) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, cg, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    /// Traced strokes placed where the picture is on the page: through its crop, scaled to its
    /// frame and turned with it. Points outside the visible (cropped) part are left out.
    @MainActor static func pageStrokes(_ traced: [TracedStroke], imageSize: (width: Int, height: Int), frame: CGRect,
                                       crop: LogicalRect?, rotation: Double) -> [PKStroke] {
        let crop = crop ?? LogicalRect(x: 0, y: 0, width: 1, height: 1)
        let sx = Double(frame.width) / (crop.width * Double(imageSize.width)), sy = Double(frame.height) / (crop.height * Double(imageSize.height))
        let center = CGPoint(x: frame.midX, y: frame.midY)
        let turn = CGAffineTransform(rotationAngle: rotation)
        func place(_ p: CanvasPoint) -> CGPoint? {
            let u = p.x / Double(imageSize.width), v = p.y / Double(imageSize.height)
            guard u >= crop.x - 1e-6, v >= crop.y - 1e-6, u <= crop.x + crop.width + 1e-6, v <= crop.y + crop.height + 1e-6 else { return nil }
            let x = Double(frame.minX) + (u - crop.x) / crop.width * Double(frame.width) - Double(center.x)
            let y = Double(frame.minY) + (v - crop.y) / crop.height * Double(frame.height) - Double(center.y)
            let local = CGPoint(x: x, y: y).applying(turn)
            return CGPoint(x: center.x + local.x, y: center.y + local.y)
        }
        var strokes: [PKStroke] = []
        let created = Date()
        for line in traced {
            let ink = PKInk(.pen, color: UIColor(hex: line.color))
            let width = max(0.5, line.width * (sx + sy) / 2)
            // Split where the line leaves the visible part of the picture.
            var runs: [[CGPoint]] = [[]]
            for point in line.points { if let placed = place(point) { runs[runs.count - 1].append(placed) } else if !(runs.last?.isEmpty ?? true) { runs.append([]) } }
            for run in runs where !run.isEmpty {
                let points = run.count == 1 ? [run[0], run[0]] : run
                let controls = points.enumerated().map { index, location in
                    PKStrokePoint(location: location, timeOffset: TimeInterval(index) * 0.016, size: CGSize(width: width, height: width),
                                  opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
                }
                strokes.append(PKStroke(ink: ink, path: PKStrokePath(controlPoints: controls, creationDate: created)))
            }
        }
        return strokes
    }
}
#endif
