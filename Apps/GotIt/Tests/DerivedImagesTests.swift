import XCTest
import ImageIO
import CryptoKit
import GotItDomain
import UniformTypeIdentifiers
@testable import GotItApp

/// Smaller copies of large pictures, kept in Caches and made again when missing.
@MainActor
final class DerivedImagesTests: XCTestCase {
    /// A fresh folder for each test, removed when the test ends.
    private lazy var folder: URL = {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }()

    private func picture(width: Int, height: Int, opaque: Bool, type: UTType) throws -> URL {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = opaque
        let image = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { context in
            if opaque { UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: width, height: height)) }
            UIColor.systemBlue.setFill(); context.fill(CGRect(x: width / 4, y: height / 4, width: width / 2, height: height / 2))
            // Noise, so the file is as large as a real photo's.
            for index in 0..<4000 {
                UIColor(hue: CGFloat(index % 97) / 97, saturation: 1, brightness: 1, alpha: 1).setFill()
                context.fill(CGRect(x: (index * 7919) % width, y: (index * 104729) % height, width: 9, height: 9))
            }
        }
        let url = folder.appendingPathComponent(UUID().uuidString)
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(image.cgImage), [kCGImageDestinationLossyCompressionQuality: 1.0] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    func testLargePhotosAreShownFromAKeptSmallerCopy() throws {
        let hash = String(repeating: "a", count: 64)
        let original = try picture(width: 3600, height: 2400, opaque: true, type: .jpeg)
        let shown = try XCTUnwrap(DerivedImages.picture(hash, original: original, in: folder))
        XCTAssertEqual(max(shown.size.width, shown.size.height), CGFloat(DerivedImages.displayPixels))
        XCTAssertEqual(shown.size.width / shown.size.height, 1.5, accuracy: 0.01)
        let kept = try XCTUnwrap(DerivedImages.url(hash, .display, in: folder))
        XCTAssertTrue(FileManager.default.fileExists(atPath: kept.path))
        let keptBytes = try XCTUnwrap(try kept.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        let originalBytes = try XCTUnwrap(try original.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        XCTAssertLessThan(keptBytes, originalBytes)
        // Next time the copy is read; the original is not decoded again.
        let again = DerivedImages.image(hash, role: .display, in: folder) { XCTFail("made again"); return nil }
        XCTAssertEqual(again?.size, shown.size)
        DerivedImages.remove(hash, in: folder)
        XCTAssertFalse(FileManager.default.fileExists(atPath: kept.path))
    }

    func testSmallPicturesAreShownAsTheyAre() throws {
        let hash = String(repeating: "b", count: 64)
        let original = try picture(width: 600, height: 400, opaque: true, type: .jpeg)
        let shown = try XCTUnwrap(DerivedImages.picture(hash, original: original, in: folder))
        XCTAssertEqual(shown.size, CGSize(width: 600, height: 400))
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(DerivedImages.url(hash, .display, in: folder)).path))
    }

    func testTransparentPicturesKeepTheirTransparency() throws {
        let hash = String(repeating: "c", count: 64)
        let original = try picture(width: 3000, height: 3000, opaque: false, type: .png)
        _ = try XCTUnwrap(DerivedImages.picture(hash, original: original, in: folder))
        let kept = try Data(contentsOf: try XCTUnwrap(DerivedImages.url(hash, .display, in: folder)))
        XCTAssertEqual(Array(kept.prefix(4)), [0x89, 0x50, 0x4E, 0x47], "PNG, not JPEG")
    }

    func testNoteThumbnailsAreKeptByRevision() throws {
        let id = UUID()
        let image = UIGraphicsImageRenderer(size: CGSize(width: 120, height: 170)).image { context in
            UIColor.yellow.setFill(); context.fill(CGRect(x: 0, y: 0, width: 120, height: 170))
        }
        XCTAssertNil(PreviewCache.load(id, revision: 3, in: folder))
        PreviewCache.store(image, id: id, revision: 3, in: folder)
        XCTAssertNotNil(PreviewCache.load(id, revision: 3, in: folder))
        // A newer revision replaces the older file; another note's thumbnail stays.
        let other = UUID()
        PreviewCache.store(image, id: other, revision: 1, in: folder)
        PreviewCache.store(image, id: id, revision: 4, in: folder)
        XCTAssertNil(PreviewCache.load(id, revision: 3, in: folder))
        XCTAssertNotNil(PreviewCache.load(id, revision: 4, in: folder))
        PreviewCache.remove(id, in: folder)
        XCTAssertNil(PreviewCache.load(id, revision: 4, in: folder))
        XCTAssertNotNil(PreviewCache.load(other, revision: 1, in: folder))
    }

    func testOnlyHashesNameCopies() {
        XCTAssertNil(DerivedImages.url("../../escape", .display, in: folder))
        XCTAssertNotNil(DerivedImages.url(String(repeating: "f", count: 64), .poster, in: folder))
    }
}

/// Audio and video are hashed in pieces and copied as files, never read whole into memory.
final class MediaImportTests: XCTestCase {
    func testLargeMediaIsHashedInPiecesAndCopiedOnce() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        // 3.5 MB: more than three pieces, the last one partial.
        let bytes = Data((0..<3_500_000).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ $0 >> 9) })
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try bytes.write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -5 * 86400)], ofItemAtPath: source.path)
        let asset = try AppModel.storeFile(source, mediaType: "video/quicktime", in: folder)
        let whole = SHA256Check.hex(bytes)
        XCTAssertEqual(asset.hash, whole)
        XCTAssertEqual(asset.byteCount, Int64(bytes.count))
        let stored = folder.appendingPathComponent(asset.hash)
        XCTAssertEqual(try Data(contentsOf: stored), bytes)
        // Dated now, so the cleanup of day-old orphans leaves it alone until it is registered.
        let date = try XCTUnwrap(try stored.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        XCTAssertGreaterThan(date, Date(timeIntervalSinceNow: -60))
        // The same file again: the same asset, no second copy.
        XCTAssertEqual(try AppModel.storeFile(source, mediaType: "video/quicktime", in: folder), asset)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), [asset.hash])
    }
}

enum SHA256Check {
    static func hex(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
