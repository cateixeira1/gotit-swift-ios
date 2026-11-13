import UIKit
import ImageIO
import UniformTypeIdentifiers

/// Smaller copies of what a page shows — a large photo, a video's first frame, a PDF's first page —
/// made once from the original and kept in the Caches folder. Reopening a note then decodes a
/// small file instead of the original (a 12-megapixel HEIC, a whole PDF, a video).
///
/// They are not part of the note: the original asset (by hash) stays the only source, a copy can
/// be made again at any time, and iOS may delete the Caches folder when space runs low. Each copy
/// is named after the original's hash and its role, so it never shows another picture.
enum DerivedImages {
    enum Role: String, CaseIterable { case display, poster, pdfPage }

    /// Longest side of the copy shown on a page (the same limit the editor used when decoding the
    /// original each time).
    static let displayPixels = 2048
    /// Originals at most this big are decoded directly: a copy would save nothing.
    static let directBytes = 1_500_000

    static var folder: URL? {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let folder = caches.appendingPathComponent("GotIt-derived", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    static func url(_ hash: String, _ role: Role, in folder: URL? = DerivedImages.folder) -> URL? {
        // Hashes are 64 hex digits; anything else never names a file here.
        guard hash.count == 64, hash.allSatisfy(\.isHexDigit) else { return nil }
        return folder?.appendingPathComponent("\(hash)-\(role.rawValue)")
    }

    /// The kept copy, or a new one made by `make` and kept for next time.
    /// `opaque`: whether the picture has no transparency (nil: read it from the image).
    static func image(_ hash: String, role: Role, in folder: URL? = DerivedImages.folder, opaque: Bool? = true, make: () -> CGImage?) -> UIImage? {
        if let url = url(hash, role, in: folder), let kept = decode(url) { return UIImage(cgImage: kept) }
        guard let made = make() else { return nil }
        if let url = url(hash, role, in: folder) { write(made, opaque: opaque, to: url) }
        return UIImage(cgImage: made)
    }

    /// A picture asset as shown on a page: small originals as they are, large ones through a copy
    /// at most `displayPixels` on its longest side (rotated upright).
    static func picture(_ hash: String, original: URL, in folder: URL? = DerivedImages.folder) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(original as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0, height = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0
        let bytes = (try? original.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? .max
        let upright = (properties?[kCGImagePropertyOrientation] as? Int ?? 1) == 1
        if max(width, height) <= displayPixels, bytes <= directBytes, upright,
           let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) {
            return UIImage(cgImage: image)
        }
        // JPEG and HEIC photos have no transparency even when decoded with an alpha channel.
        let opaque = (properties?[kCGImagePropertyHasAlpha] as? Bool).map { !$0 }
        return image(hash, role: .display, in: folder, opaque: opaque) { downsampled(source, maxPixels: displayPixels) }
    }

    static func downsampled(_ source: CGImageSource, maxPixels: Int) -> CGImage? {
        CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                        kCGImageSourceThumbnailMaxPixelSize: maxPixels,
                                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                                        kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    /// Removes every copy made from `hash` (its original was deleted).
    static func remove(_ hash: String, in folder: URL? = DerivedImages.folder) {
        for role in Role.allCases { if let url = url(hash, role, in: folder) { try? FileManager.default.removeItem(at: url) } }
    }

    private static func decode(_ url: URL) -> CGImage? {
        guard FileManager.default.fileExists(atPath: url.path),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    /// JPEG for opaque pictures, PNG where there is transparency (stickers, cut-out photos).
    /// Written to a temporary file and moved, so a half-written copy is never read.
    private static func write(_ image: CGImage, opaque: Bool?, to url: URL) {
        let noAlpha: Set<CGImageAlphaInfo> = [.none, .noneSkipFirst, .noneSkipLast]
        let type = (opaque ?? noAlpha.contains(image.alphaInfo)) ? UTType.jpeg : UTType.png
        let temporary = url.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        guard let destination = CGImageDestinationCreateWithURL(temporary as CFURL, type.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { try? FileManager.default.removeItem(at: temporary); return }
        try? FileManager.default.removeItem(at: url)
        do { try FileManager.default.moveItem(at: temporary, to: url) } catch { try? FileManager.default.removeItem(at: temporary) }
    }
}

/// Note thumbnails kept on disk by revision. Starting the app (or coming back to the list) shows
/// each note's thumbnail without opening the note again; only a note that changed since its
/// thumbnail was made is opened and drawn. The previous revision's file is removed when a newer
/// one is written. Like the other copies, they live in Caches and are made again when missing.
enum PreviewCache {
    /// Raised when thumbnails are drawn differently, so older ones are not reused.
    static let drawingVersion = 1

    static var folder: URL? {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let folder = caches.appendingPathComponent("GotIt-previews", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    static func url(_ id: UUID, revision: Int64, in folder: URL? = PreviewCache.folder) -> URL? {
        folder?.appendingPathComponent("\(id.uuidString)-r\(revision)-v\(drawingVersion).png")
    }

    static func load(_ id: UUID, revision: Int64, in folder: URL? = PreviewCache.folder) -> UIImage? {
        guard let url = url(id, revision: revision, in: folder), let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }

    static func store(_ image: UIImage, id: UUID, revision: Int64, in folder: URL? = PreviewCache.folder) {
        guard let url = url(id, revision: revision, in: folder), let data = image.pngData() else { return }
        try? data.write(to: url, options: .atomic)
        remove(id, keeping: url.lastPathComponent, in: folder)
    }

    /// Removes the note's thumbnails (all of them, or all but `keeping`).
    static func remove(_ id: UUID, keeping: String? = nil, in folder: URL? = PreviewCache.folder) {
        guard let folder, let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return }
        for name in names where name.hasPrefix(id.uuidString + "-") && name != keeping {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
    }
}
