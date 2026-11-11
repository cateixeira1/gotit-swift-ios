import Foundation
import AVFoundation
import Speech

/// Speech to text on the device, nothing sent anywhere.
///
/// iOS 26: `SpeechAnalyzer` with `SpeechTranscriber` (long-form, offline; the language model is
/// downloaded once by the system the first time a language is used). Earlier systems:
/// `SFSpeechRecognizer` restricted to on-device recognition, which Apple recommends for audio of
/// about a minute; longer recordings may come back incomplete there.
enum AudioTranscription {
    enum Failure: LocalizedError {
        case notAllowed, unsupportedLanguage, unavailable
        var errorDescription: String? {
            switch self {
            case .notAllowed: "O Got It! não tem permissão para reconhecer fala. Ative em Ajustes › Got It!."
            case .unsupportedLanguage: "Este idioma não pode ser transcrito no aparelho."
            case .unavailable: "A transcrição no aparelho não está disponível agora."
            }
        }
    }

    /// Languages offered for transcription (identifier, name). Portuguese (Brazil) by default:
    /// following the device would transcribe Portuguese speech as English on a phone set to English.
    static let languages: [(id: String, name: String)] = [
        ("pt-BR", "Português (Brasil)"), ("pt-PT", "Português (Portugal)"), ("en-US", "Inglês (EUA)"),
        ("es-ES", "Espanhol"), ("it-IT", "Italiano"), ("fr-FR", "Francês"), ("de-DE", "Alemão"),
    ]
    static let languageKey = "transcriptionLanguage"
    static var language: Locale { Locale(identifier: UserDefaults.standard.string(forKey: languageKey) ?? "pt-BR") }

    struct Result: Sendable { var text: String; var engine: String; var language: String; var seconds: Double = 0 }

    static func transcribe(_ url: URL, locale: Locale = language) async throws -> Result {
        let seconds = (try? AVAudioFile(forReading: url)).map { Double($0.length) / $0.processingFormat.sampleRate } ?? 0
        if #available(iOS 26.0, *) {
            return Result(text: try await analyze(url, locale: locale), engine: "SpeechAnalyzer", language: locale.identifier, seconds: seconds)
        }
        return Result(text: try await recognizeInPieces(url, locale: locale), engine: "SFSpeechRecognizer", language: locale.identifier, seconds: seconds)
    }

    /// Before iOS 26 the recognizer is meant for about a minute of audio: the file is cut in
    /// 50-second pieces, each recognised on the device, and the texts joined.
    private static func recognizeInPieces(_ url: URL, locale: Locale) async throws -> String {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let piece = AVAudioFrameCount(format.sampleRate * 50)
        var texts: [String] = []
        while file.framePosition < file.length {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: piece) else { break }
            try file.read(into: buffer, frameCount: piece)
            guard buffer.frameLength > 0 else { break }
            let chunk = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("caf")
            do {
                let out = try AVAudioFile(forWriting: chunk, settings: format.settings, commonFormat: format.commonFormat, interleaved: format.isInterleaved)
                try out.write(from: buffer)
            }
            defer { try? FileManager.default.removeItem(at: chunk) }
            let text = try await recognize(chunk, locale: locale)
            if !text.isEmpty { texts.append(text) }
        }
        return texts.joined(separator: " ")
    }

    /// The file is read in pieces, converted to the analyzer's own audio format (sample rate,
    /// channels) and fed as a continuous stream; the text is the finished results joined in order.
    @available(iOS 26.0, *)
    private static func analyze(_ url: URL, locale: Locale) async throws -> String {
        guard SpeechTranscriber.isAvailable else { throw Failure.unavailable }
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else { throw Failure.unsupportedLanguage }
        let transcriber = SpeechTranscriber(locale: supported, preset: .transcription)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        let file = try AVAudioFile(forReading: url)
        guard let target = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else { throw Failure.unavailable }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let (input, feed) = AsyncStream.makeStream(of: AnalyzerInput.self)
        let collected = Task {
            var text = ""
            for try await result in transcriber.results where result.isFinal {
                let phrase = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !phrase.isEmpty else { continue }
                text += (text.isEmpty ? "" : " ") + phrase
            }
            return text
        }
        try await analyzer.start(inputSequence: input)
        do {
            for buffer in try converted(file, to: target) { feed.yield(AnalyzerInput(buffer: buffer)) }
            feed.finish()
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            feed.finish(); await analyzer.cancelAndFinishNow(); collected.cancel()
            throw error
        }
        return try await collected.value
    }

    /// The whole file as buffers of about 2 seconds in `format`.
    static func converted(_ file: AVAudioFile, to format: AVAudioFormat) throws -> [AVAudioPCMBuffer] {
        // The converter's input block may be @Sendable in newer SDKs; it runs synchronously here.
        nonisolated(unsafe) let file = file
        nonisolated(unsafe) let source = file.processingFormat
        guard let converter = AVAudioConverter(from: source, to: format) else { throw Failure.unavailable }
        let chunk = AVAudioFrameCount(source.sampleRate * 2)
        var output: [AVAudioPCMBuffer] = []
        var finished = false
        while !finished {
            let capacity = AVAudioFrameCount(Double(chunk) * format.sampleRate / source.sampleRate) + 1024
            guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { break }
            var conversionError: NSError?
            let status = converter.convert(to: out, error: &conversionError) { packets, inputStatus in
                guard file.framePosition < file.length,
                      let buffer = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: min(packets, chunk)),
                      (try? file.read(into: buffer, frameCount: min(packets, chunk))) != nil, buffer.frameLength > 0 else {
                    inputStatus.pointee = .endOfStream; return nil
                }
                inputStatus.pointee = .haveData
                return buffer
            }
            if let conversionError { throw conversionError }
            if out.frameLength > 0 { output.append(out) }
            if status == .endOfStream || status == .error { finished = true }
        }
        return output
    }

    private static func recognize(_ url: URL, locale: Locale) async throws -> String {
        let status = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard status == .authorized else { throw Failure.notAllowed }
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else { throw Failure.unsupportedLanguage }
        guard recognizer.supportsOnDeviceRecognition else { throw Failure.unavailable }
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        return try await withCheckedThrowingContinuation { continuation in
            let once = Once()
            recognizer.recognitionTask(with: request) { result, error in
                if let result, result.isFinal { if once.claim() { continuation.resume(returning: result.bestTranscription.formattedString) } }
                else if let error { if once.claim() { continuation.resume(throwing: error) } }
            }
        }
    }

    /// The recognizer may call back more than once; the continuation is resumed the first time only.
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func claim() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
    }
}
