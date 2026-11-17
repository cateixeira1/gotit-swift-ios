import AVFoundation

/// A smaller copy of a video, for when space matters more than the original's quality. Always the
/// user's choice: when inserting (Ferramentas › Vídeos ao inserir) or later, from the video's menu.
/// The original is never changed; the note points to the copy, and undo brings the original back
/// while the history still holds it.
@MainActor enum VideoReduction {
    enum Quality: String, CaseIterable, Identifiable, Sendable {
        case high, medium
        var id: String { rawValue }
        var title: String {
            switch self {
            case .high: "Alta (até 1080p)"
            case .medium: "Média (até 720p)"
            }
        }
        /// Export presets, best first: HEVC where the device encodes it, else H.264.
        var presets: [String] {
            switch self {
            case .high: [AVAssetExportPresetHEVC1920x1080, AVAssetExportPreset1920x1080]
            case .medium: [AVAssetExportPreset1280x720]
            }
        }
    }

    /// Setting for videos being inserted: "original" (default) or a quality's raw value.
    static let importKey = "videoImportReduction"

    /// Below this share of the original's size a copy is worth keeping (10 % saved at least).
    static let worthwhile = 0.9

    /// The reduced copy as an MP4 in a temporary file, or nil when it would not save space.
    static func reduce(_ asset: AVURLAsset, originalBytes: Int64, quality: Quality) async throws -> URL? {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("mp4")
        var exported = false
        for preset in quality.presets {
            guard await AVAssetExportSession.compatibility(ofExportPreset: preset, with: asset, outputFileType: .mp4),
                  let session = AVAssetExportSession(asset: asset, presetName: preset) else { continue }
            session.shouldOptimizeForNetworkUse = true
            try? FileManager.default.removeItem(at: output)
            do { try await session.export(to: output, as: .mp4); exported = true; break }
            catch { try? FileManager.default.removeItem(at: output); if preset == quality.presets.last { throw error } }
        }
        guard exported else { throw Failure.unsupported }
        let bytes = Int64((try? output.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? .max)
        guard Double(bytes) < Double(originalBytes) * worthwhile else {
            try? FileManager.default.removeItem(at: output); return nil
        }
        return output
    }

    enum Failure: LocalizedError {
        case unsupported
        var errorDescription: String? { "Este vídeo não pode ser reduzido neste aparelho." }
    }

    static func megabytes(_ bytes: Int64) -> String {
        let value = Double(bytes) / 1_000_000
        return value < 10 ? String(format: "%.1f MB", value).replacingOccurrences(of: ".", with: ",") : "\(Int(value.rounded())) MB"
    }
}
