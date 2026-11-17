import SwiftUI
import AVFoundation

/// Records audio for a note: record, pause and continue, then "Concluir" puts it on the page
/// (and transcribes it on the device when "Transcrever" is on).
@MainActor @Observable final class AudioRecording {
    enum State { case idle, recording, paused }
    private(set) var state = State.idle
    private(set) var elapsed: TimeInterval = 0
    /// Recent input levels (0…1), newest last, for the meter.
    private(set) var levels: [Double] = Array(repeating: 0, count: 40)
    var problem: String?
    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("gravacao-\(UUID().uuidString).m4a")

    func start() async {
        guard await AVAudioApplication.requestRecordPermission() else {
            problem = "O Got It! não tem acesso ao microfone. Ative em Ajustes › Got It! › Microfone."; return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)
            let recorder = try AVAudioRecorder(url: url, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            ])
            recorder.isMeteringEnabled = true
            guard recorder.record() else { problem = "Não foi possível começar a gravar."; return }
            self.recorder = recorder; state = .recording
            timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
        } catch { problem = "Não foi possível começar a gravar: \(error.localizedDescription)" }
    }

    private func tick() {
        guard let recorder else { return }
        elapsed = recorder.currentTime
        guard state == .recording else { return }
        recorder.updateMeters()
        let power = Double(recorder.averagePower(forChannel: 0))          // dBFS, -160…0
        levels.removeFirst(); levels.append(max(0, min(1, (power + 50) / 50)))
    }

    func pause() { recorder?.pause(); state = .paused }
    func resume() { if recorder?.record() == true { state = .recording } }

    /// Stops and returns the file (nil if nothing was recorded).
    func finish() -> URL? {
        timer?.invalidate(); timer = nil
        let recorded = (recorder?.currentTime ?? elapsed) > 0.3 || elapsed > 0.3
        recorder?.stop(); recorder = nil; state = .idle
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        return recorded ? url : nil
    }

    func discard() {
        _ = finish()
        try? FileManager.default.removeItem(at: url)
    }
}

struct AudioRecorderView: View {
    let onDone: (URL, AppModel.TranscriptPlacement?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var recording = AudioRecording()
    @AppStorage("transcribeRecordings") private var transcribe = true
    @AppStorage("transcriptPlacement") private var placement = AppModel.TranscriptPlacement.card.rawValue
    @AppStorage(AudioTranscription.languageKey) private var language = "pt-BR"

    var body: some View {
        NavigationStack {
            VStack(spacing: 28) {
                Text(time(recording.elapsed)).font(.system(size: 48, weight: .light, design: .rounded).monospacedDigit())
                    .accessibilityIdentifier("recordingTime")
                HStack(alignment: .center, spacing: 3) {
                    ForEach(Array(recording.levels.enumerated()), id: \.offset) { _, level in
                        Capsule().fill(recording.state == .recording ? Color.red : Color.secondary.opacity(0.5))
                            .frame(width: 4, height: 6 + 54 * level)
                    }
                }.frame(height: 64).accessibilityHidden(true)
                HStack(spacing: 40) {
                    Button { recording.discard(); dismiss() } label: { Image(systemName: "trash").font(.title2) }
                        .accessibilityLabel("Descartar gravação").disabled(recording.state == .idle)
                    Button {
                        switch recording.state {
                        case .idle: Task { await recording.start() }
                        case .recording: recording.pause()
                        case .paused: recording.resume()
                        }
                    } label: {
                        ZStack {
                            Circle().stroke(Color.secondary.opacity(0.4), lineWidth: 4).frame(width: 78, height: 78)
                            if recording.state == .recording { RoundedRectangle(cornerRadius: 6).fill(.red).frame(width: 30, height: 30) }
                            else { Circle().fill(.red).frame(width: 62, height: 62) }
                        }
                    }
                    .accessibilityLabel(recording.state == .recording ? "Pausar" : recording.state == .paused ? "Continuar gravando" : "Gravar")
                    .accessibilityIdentifier("recordButton")
                    Button {
                        if let url = recording.finish() { onDone(url, transcribe ? AppModel.TranscriptPlacement(rawValue: placement) ?? .card : nil) }
                        dismiss()
                    } label: { Image(systemName: "checkmark.circle.fill").font(.title) }
                        .accessibilityLabel("Concluir gravação").disabled(recording.state == .idle)
                }
                VStack(spacing: 10) {
                    Toggle("Transcrever no aparelho ao concluir", isOn: $transcribe)
                    if transcribe {
                        Picker("Transcrição", selection: $placement) {
                            Text("Bloco ao lado").tag(AppModel.TranscriptPlacement.card.rawValue)
                            Text("Texto na nota").tag(AppModel.TranscriptPlacement.text.rawValue)
                        }.pickerStyle(.segmented)
                        Picker("Idioma", selection: $language) {
                            ForEach(AudioTranscription.languages, id: \.id) { Text($0.name).tag($0.id) }
                        }
                    }
                }.padding(.horizontal)
                if let problem = recording.problem { Text(problem).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center).padding(.horizontal) }
                Spacer(minLength: 0)
            }
            .padding(.top, 30)
            .navigationTitle("Gravar áudio").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { recording.discard(); dismiss() } } }
            .task { await recording.start() }
        }
        .interactiveDismissDisabled(recording.state != .idle)
    }

    private func time(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
