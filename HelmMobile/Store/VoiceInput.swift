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
    @ObservationIgnored private var meter: Task<Void, Never>?
    @ObservationIgnored private var lastRecording: URL?
    @ObservationIgnored private var lastDuration: TimeInterval = 0
    static let maxDuration: TimeInterval = 5 * 60

    var isRecording: Bool { if case .recording = state { true } else { false } }

    func start(handsFree: Bool) async {
        guard !isRecording else { return }
        guard await AVAudioApplication.requestRecordPermission() else {
            state = .failed(String(localized: "Microphone access is off. Turn it on in Settings."))
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .allowBluetoothHFP])
            try session.setActive(true)
            let url = FileManager.default.temporaryDirectory.appending(path: "dictation-\(UUID().uuidString).m4a")
            let recorder = try AVAudioRecorder(url: url, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            ])
            recorder.isMeteringEnabled = true
            guard recorder.record(forDuration: Self.maxDuration) else { throw VoiceError.recorderFailed }
            self.recorder = recorder
            lastRecording = url
            startedAt = Date()
            levels = []
            state = .recording(handsFree: handsFree)
            UIApplication.shared.isIdleTimerDisabled = true
            meter = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(80))
                    self?.sample()
                }
            }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func sample() {
        guard let recorder, recorder.isRecording else { return }
        recorder.updateMeters()
        let power = recorder.averagePower(forChannel: 0)  // -160...0 dB
        level = max(0, min(1, (Double(power) + 50) / 50))
        levels.append(level)
        if levels.count > 48 { levels.removeFirst(levels.count - 48) }
    }

    func cancel() {
        stopRecorder()
        if let lastRecording { try? FileManager.default.removeItem(at: lastRecording) }
        lastRecording = nil
        state = .idle
    }

    /// Stops recording and returns the text, or nil when cancelled / failed (state says why).
    func finish(environment: EnvironmentSession, threadId: String?) async -> String? {
        guard isRecording else { return nil }
        lastDuration = recorder?.currentTime ?? Date().timeIntervalSince(startedAt ?? Date())
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
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
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
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard status == .authorized, let recognizer = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer(),
              recognizer.isAvailable
        else { throw VoiceError.unavailable }
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        return try await withCheckedThrowingContinuation { continuation in
            var resumed = false
            recognizer.recognitionTask(with: request) { result, error in
                guard !resumed else { return }
                if let error {
                    resumed = true
                    continuation.resume(throwing: error)
                } else if let result, result.isFinal {
                    resumed = true
                    continuation.resume(returning: result.bestTranscription.formattedString)
                }
            }
        }
    }

    enum VoiceError: Error { case recorderFailed, unavailable }
}
