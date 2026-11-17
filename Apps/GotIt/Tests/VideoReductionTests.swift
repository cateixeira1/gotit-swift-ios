import XCTest
import AVFoundation
@testable import GotItApp

/// Reducing a video is the user's choice; the copy must be smaller and at most the chosen size.
@MainActor
final class VideoReductionTests: XCTestCase {
    /// One second of 1080p noise at a high bit rate (noise keeps the encoder from saving space).
    private func noisyVideo() async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 1920, AVVideoHeightKey: 1080,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 24_000_000],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 1920, kCVPixelBufferHeightKey as String: 1080,
        ])
        writer.add(input)
        XCTAssertTrue(writer.startWriting()); writer.startSession(atSourceTime: .zero)
        var seed: UInt32 = 12345
        for frame in 0..<30 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, try XCTUnwrap(adaptor.pixelBufferPool), &buffer)
            let pixels = try XCTUnwrap(buffer)
            CVPixelBufferLockBaseAddress(pixels, [])
            let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixels)).assumingMemoryBound(to: UInt32.self)
            let count = CVPixelBufferGetBytesPerRow(pixels) / 4 * 1080
            for index in 0..<count { seed = seed &* 1664525 &+ 1013904223; base[index] = seed | 0xFF00_0000 }
            CVPixelBufferUnlockBaseAddress(pixels, [])
            XCTAssertTrue(adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed, String(describing: writer.error))
        return url
    }

    func testAReducedCopyIsSmallerAndAtMost720p() async throws {
        let original = try await noisyVideo()
        defer { try? FileManager.default.removeItem(at: original) }
        let bytes = Int64(try XCTUnwrap(try original.resourceValues(forKeys: [.fileSizeKey]).fileSize))
        let copy = try await VideoReduction.reduce(AVURLAsset(url: original), originalBytes: bytes, quality: .medium)
        let reduced = try XCTUnwrap(copy)
        defer { try? FileManager.default.removeItem(at: reduced) }
        let reducedBytes = Int64(try XCTUnwrap(try reduced.resourceValues(forKeys: [.fileSizeKey]).fileSize))
        XCTAssertLessThan(Double(reducedBytes), Double(bytes) * VideoReduction.worthwhile)
        let tracks = try await AVURLAsset(url: reduced).loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let size = try await track.load(.naturalSize)
        XCTAssertLessThanOrEqual(max(size.width, size.height), 1280)
        // A copy that would not save at least 10 % is not kept.
        let pointless = try await VideoReduction.reduce(AVURLAsset(url: reduced), originalBytes: reducedBytes / 4, quality: .medium)
        XCTAssertNil(pointless)
        XCTAssertEqual(VideoReduction.megabytes(84_400_000), "84 MB")
        XCTAssertEqual(VideoReduction.megabytes(2_340_000), "2,3 MB")
    }
}
