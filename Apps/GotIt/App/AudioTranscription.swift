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

    /// The language of the transcription: the device's, Portuguese (Brazil) if it has none.
    static var language: Locale { Locale.current.language.languageCode == nil ? Locale(identifier: "pt-BR") : Locale.current }

    static func transcribe(_ url: URL, locale: Locale = language) async throws -> String {
        if #available(iOS 26.0, *) { return try await analyze(url, locale: locale) }
        return try await recognize(url, locale: locale)
    }

    @available(iOS 26.0, *)
    private static func analyze(_ url: URL, locale: Locale) async throws -> String {
        guard SpeechTranscriber.isAvailable else { throw Failure.unavailable }
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else { throw Failure.unsupportedLanguage }
        let transcriber = SpeechTranscriber(locale: supported, preset: .transcription)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        let file = try AVAudioFile(forReading: url)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let collected = Task {
            var text = ""
            for try await result in transcriber.results {
                let phrase = String(result.text.characters).trimmingCharacters(in: .whitespaces)
                guard !phrase.isEmpty else { continue }
                text += (text.isEmpty ? "" : " ") + phrase
            }
            return text
        }
        if let last = try await analyzer.analyzeSequence(from: file) {
            try await analyzer.finalizeAndFinish(through: last)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        return try await collected.value
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
