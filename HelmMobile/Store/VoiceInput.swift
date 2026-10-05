import AVFoundation
import Foundation
import Observation
import Speech
import UIKit

/// Dictation for the composer. Records AAC (.m4a); Helm transcribes it on the Mac's side
/// (gpt-transcribe through the Volna core, Russian and English in one take). Servers without
/// `voiceTranscription` fall back to Apple's recogniser on the phone.
@MainActor
@Observable
final class VoiceInput {
    enum State: Equatable {
        case idle
        case recording(handsFree: Bool)
        case transcribing
        case failed(String)
    }

    private(set) var state = State.idle
    private(set) var startedAt: Date?
    /// 0...1, sampled ~12 times a second while recording.
    private(set) var level: Double = 0
    private(set) var levels: [Double] = []

    @ObservationIgnored private var recorder: AVAudioRecorder?
    /// The microphone opening behind a recording that already shows.
    @ObservationIgnored private var opening: Task<Void, Never>?
    /// Bumped by every begin and cancel, so a microphone that opens late for a take that is
    /// already gone gets closed instead of picked up.
    @ObservationIgnored private var take = 0
    @ObservationIgnored private var closing: Task<Void, Never>?
    @ObservationIgnored private var meter: Task<Void, Never>?
    @ObservationIgnored private var lastRecording: URL?
    @ObservationIgnored private var lastDuration: TimeInterval = 0
    static let maxDuration: TimeInterval = 5 * 60
    /// How long the audio session stays up after a recording, so the next one starts warm.
    static let sessionLinger: Duration = .seconds(6)

    var isRecording: Bool { if case .recording = state { true } else { false } }

    /// Sets the audio category ahead of time (cheap, and other audio keeps playing), so the first
    /// touch only has to activate the session.
    func warmUp() {
        Task { await MicrophoneSession.shared.configure() }
    }

    /// Touch-down, before the button knows whether it's a hold or a tap: the recording shows at
    /// once and the microphone opens behind it, so neither the eye nor the first words wait.
    /// A tap then turns it hands-free with `keepHandsFree`.
    func begin(handsFree: Bool = false) {
        guard state == .idle, opening == nil, recorder == nil else { return }
        take += 1
        let take = take
        closing?.cancel()
        closing = nil
        state = .recording(handsFree: handsFree)
        startedAt = Date()
        level = 0
        levels = []
        UIApplication.shared.isIdleTimerDisabled = true
        opening = Task { await open(take: take) }
    }

    func keepHandsFree() {
        if state == .recording(handsFree: false) { state = .recording(handsFree: true) }
    }

    private func open(take: Int) async {
        let url = FileManager.default.temporaryDirectory.appending(path: "dictation-\(UUID().uuidString).m4a")
        let opened: Result<RecorderBox, Error>
        var allowed = AVAudioApplication.shared.recordPermission == .granted
        if !allowed { allowed = await AVAudioApplication.requestRecordPermission() }
        if allowed {
            do {
                opened = .success(try await MicrophoneSession.shared.open(url: url, maxDuration: Self.maxDuration))
            } catch {
                opened = .failure(error)
            }
        } else {
            opened = .failure(VoiceError.denied)
        }
        guard take == self.take, isRecording else {
            // Released or cancelled while the microphone was opening.
            if case .success(let box) = opened {
                box.recorder.stop()
                try? FileManager.default.removeItem(at: url)
                closeLater()
            }
            return
        }
        opening = nil
        switch opened {
        case .success(let box):
            recorder = box.recorder
            lastRecording = url
            meter = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(80))
                    self?.sample()
                }
            }
        case .failure(VoiceError.denied):
            UIApplication.shared.isIdleTimerDisabled = false
            state = .failed(String(localized: "Microphone access is off. Turn it on in Settings."))
        case .failure(let error):
            UIApplication.shared.isIdleTimerDisabled = false
            closeLater()
            state = .failed(error.localizedDescription)
        }
    }

    private func sample() {
        guard let recorder, recorder.isRecording else { return }
        recorder.updateMeters()
        // The measurement mode records without gain, so speech sits low: map -44...-10 dB, lean on
        // the peak (livelier than the average) and lift the quiet end so the bars follow the voice.
        let power = Double(max(recorder.averagePower(forChannel: 0), recorder.peakPower(forChannel: 0) - 7))
        let linear = max(0, min(1, (power + 44) / 34))
        level = pow(linear, 0.65)
        levels.append(level)
        if levels.count > 48 { levels.removeFirst(levels.count - 48) }
    }

    func cancel() {
        take += 1
        opening = nil
        stopRecorder()
        if let lastRecording { try? FileManager.default.removeItem(at: lastRecording) }
        lastRecording = nil
        if isRecording { state = .idle }
    }

    /// Stops recording and returns the text, or nil when cancelled / failed (state says why).
    func finish(environment: EnvironmentSession, threadId: String?) async -> String? {
        guard isRecording else { return nil }
        if let opening { await opening.value }
        guard isRecording, recorder != nil else { return nil }
        // currentTime reads 0 once the recorder stopped itself at the cap; use the wall clock.
        let elapsed = Date().timeIntervalSince(startedAt ?? Date())
        lastDuration = min(Self.maxDuration, (recorder?.isRecording == true ? recorder?.currentTime : nil) ?? elapsed)
        stopRecorder()
        guard lastDuration >= 0.4 else {
            cancel()
            return nil
        }
        return await transcribe(environment: environment, threadId: threadId)
    }

    /// After a failure the recording is kept, so "Retry" doesn't ask to speak again.
    func retry(environment: EnvironmentSession, threadId: String?) async -> String? {
        guard lastRecording != nil else {
            state = .idle
            return nil
        }
        return await transcribe(environment: environment, threadId: threadId)
    }

    func dismissError() {
        if let lastRecording { try? FileManager.default.removeItem(at: lastRecording) }
        lastRecording = nil
        state = .idle
    }

    private func stopRecorder() {
        meter?.cancel()
        meter = nil
        recorder?.stop()
        recorder = nil
        UIApplication.shared.isIdleTimerDisabled = false
        closeLater()
    }

    /// Lets the session go a little after the recording, unless the next one starts first.
    private func closeLater() {
        closing?.cancel()
        closing = Task {
            try? await Task.sleep(for: Self.sessionLinger)
            guard !Task.isCancelled, recorder == nil, opening == nil else { return }
            closing = nil
            await MicrophoneSession.shared.close()
        }
    }

    private func transcribe(environment: EnvironmentSession, threadId: String?) async -> String? {
        guard let url = lastRecording else { return nil }
        state = .transcribing
        do {
            let text: String
            if environment.config?.capability("voiceTranscription") == true {
                text = try await serverTranscription(url: url, environment: environment, threadId: threadId)
            } else {
                text = try await deviceTranscription(url: url)
            }
            try? FileManager.default.removeItem(at: url)
            lastRecording = nil
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                state = .failed(String(localized: "Couldn't transcribe the recording."))
                return nil
            }
            state = .idle
            return trimmed
        } catch {
            state = .failed(String(localized: "Couldn't transcribe the recording."))
            return nil
        }
    }

    private func serverTranscription(url: URL, environment: EnvironmentSession, threadId: String?) async throws -> String {
        let data = try Data(contentsOf: url)
        let attachment = try await environment.upload(data: data, name: "dictation.m4a", mimeType: "audio/mp4", type: "file")
        var payload: [String: JSON] = ["attachmentId": .string(attachment.id)]
        if let threadId { payload["threadId"] = .string(threadId) }
        if lastDuration > 0 { payload["durationSeconds"] = .number(lastDuration.rounded(.up)) }
        let result = try await environment.call("voice.transcribe", .object(payload), timeout: .seconds(100))
        return result["text"]?.string ?? ""
    }

    private func deviceTranscription(url: URL) async throws -> String {
        let status = await withCheckedContinuation { continuation in
            // @Sendable: these callbacks arrive off the main thread, and a closure written in this
            // main-actor class would otherwise be assumed main-actor and trap there.
            SFSpeechRecognizer.requestAuthorization { @Sendable status in continuation.resume(returning: status) }
        }
        guard status == .authorized, let recognizer = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer(),
              recognizer.isAvailable
        else { throw VoiceError.unavailable }
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        let gate = OnceGate()
        let text = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                let task = recognizer.recognitionTask(with: request) { @Sendable result, error in
                    if let error {
                        if gate.claim() { continuation.resume(throwing: error) }
                    } else if let result, result.isFinal {
                        if gate.claim() { continuation.resume(returning: result.bestTranscription.formattedString) }
                    }
                }
                // Never leave the composer stuck on "Transcribing…".
                DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
                    if gate.claim() {
                        task.cancel()
                        continuation.resume(throwing: VoiceError.unavailable)
                    }
                }
        }
        withExtendedLifetime(recognizer) {}  // keep the recogniser alive until it answered
        return text
    }

    enum VoiceError: Error { case recorderFailed, unavailable, denied }
}

/// Owns the audio session off the main thread: activating it takes a noticeable moment, and on
/// the main actor that moment froze the button under the finger. Being an actor also keeps a
/// late close from landing after the next open.
private actor MicrophoneSession {
    static let shared = MicrophoneSession()

    /// Records from the phone's own microphone and leaves other audio alone: music keeps playing,
    /// and Bluetooth headphones or a car stay on A2DP instead of dropping to call-quality HFP.
    /// The phone is held at the mouth anyway, and its microphone beats theirs.
    func configure() {
        let session = AVAudioSession.sharedInstance()
        let options: AVAudioSession.CategoryOptions = [.defaultToSpeaker, .allowBluetoothA2DP, .mixWithOthers]
        guard session.category != .playAndRecord || session.mode != .measurement || session.categoryOptions != options
        else { return }
        try? session.setCategory(.playAndRecord, mode: .measurement, options: options)
        // iOS mutes haptics while the microphone records, and recording starts at touch-down:
        // without this the "it's a hold" tap and the slide-to-cancel tick went missing.
        try? session.setAllowHapticsAndSystemSoundsDuringRecording(true)
    }

    func open(url: URL, maxDuration: TimeInterval) throws -> RecorderBox {
        configure()
        let session = AVAudioSession.sharedInstance()
        try session.setActive(true)
        // A wired headset or CarPlay could still offer its own microphone; ask for the phone's.
        if session.currentRoute.inputs.first?.portType != .builtInMic,
           let builtIn = session.availableInputs?.first(where: { $0.portType == .builtInMic }) {
            try? session.setPreferredInput(builtIn)
        }
        let recorder = try AVAudioRecorder(url: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ])
        recorder.isMeteringEnabled = true
        guard recorder.record(forDuration: maxDuration) else { throw VoiceInput.VoiceError.recorderFailed }
        return RecorderBox(recorder: recorder)
    }

    func close() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

/// Hands a freshly started recorder over to the main actor, which owns it from then on.
private struct RecorderBox: @unchecked Sendable {
    let recorder: AVAudioRecorder
}

/// Lets exactly one of several racing callbacks resume a continuation.
private final class OnceGate: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}
