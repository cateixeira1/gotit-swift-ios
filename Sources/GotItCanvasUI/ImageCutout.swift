#if canImport(UIKit)
import UIKit
import Vision
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import GotItDomain
import GotItCanvas

/// Background removal of a picture on the page.
///
/// - Photos (a person, an object, an animal): Vision's subject lifting
///   (`VNGenerateForegroundInstanceMaskRequest`, iOS 17) keeps the subjects and clears the rest.
/// - Drawings and writing on paper or a whiteboard: the light paper is made transparent
///   (`PaperRemoval.removingPaper`); subject lifting is not made for line drawings.
///   This is also the fallback when Vision finds no subject or cannot run (the simulator).
/// Either result can then be retouched with a brush (`MaskBrush`) in the preview.
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
        return Cutout(image: PaperRemoval.removingPaper(image), method: .paper)
    }

    /// What the preview shows and what "Aplicar" uses.
    struct Processed: Sendable {
        var cutout: Cutout
        /// Said to the user when the chosen method could not do its job.
        var note: String?
    }

    /// Runs off the main thread: the chosen method, no guessing.
    static func process(_ source: RasterImage, method: Method, sensitivity: Double) -> Processed {
        if method == .subject, let subject = liftSubject(source) { return Processed(cutout: Cutout(image: subject, method: .subject)) }
        return Processed(cutout: Cutout(image: PaperRemoval.removingPaper(source, sensitivity: sensitivity), method: .paper),
                         note: method == .subject ? "Nenhum objeto foi encontrado na foto; foi usado o modo Papel ou quadro." : nil)
    }

    /// The cut-out with a retouched mask: its colours where it kept the picture, the original
    /// picture's colours where the brush brought pixels back.
    static func composed(_ cutout: RasterImage, source: RasterImage, mask: [UInt8]) -> RasterImage {
        var output = cutout
        let sameSize = cutout.width == source.width && cutout.height == source.height
        for i in 0..<(cutout.width * cutout.height) {
            if sameSize, cutout.rgba[i * 4 + 3] == 0 { for c in 0..<3 { output.rgba[i * 4 + c] = source.rgba[i * 4 + c] } }
            output.rgba[i * 4 + 3] = mask[i]
        }
        return output
    }

    static func png(_ image: RasterImage) -> Data? {
        guard let cg = cgImage(image) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, cg, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}
#endif
