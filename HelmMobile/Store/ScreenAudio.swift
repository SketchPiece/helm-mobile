import AVFoundation

/// The computer's sound: 16-bit stereo chunks from the screen remote, played as they come.
/// A little is buffered before playing so the network's unevenness doesn't stutter; when it's
/// more than a fraction of a second behind, chunks are dropped rather than heard late.
@MainActor
final class ScreenAudio {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var format: AVAudioFormat?
    /// Frames handed to the player and not yet played.
    private var queued = 0

    /// `[u8 channels][u32 big-endian sample rate][Int16 little-endian samples, interleaved]`.
    func play(_ payload: Data) {
        guard payload.count > 5 else { return }
        let bytes = [UInt8](payload)
        let channels = max(1, Int(bytes[0]))
        let rate = Double(UInt32(bytes[1]) << 24 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 8 | UInt32(bytes[4]))
        guard rate > 0, let format = format(rate: rate) else { return }
        let frames = (bytes.count - 5) / (2 * channels)
        guard frames > 0, queued < Int(rate * 0.3),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let output = buffer.floatChannelData else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        bytes.withUnsafeBufferPointer { raw in
            raw.baseAddress!.advanced(by: 5).withMemoryRebound(to: Int16.self, capacity: frames * channels) { samples in
                for frame in 0..<frames {
                    for channel in 0..<2 {
                        let value = Int16(littleEndian: samples[frame * channels + min(channel, channels - 1)])
                        output[channel][frame] = Float(value) / 32768
                    }
                }
            }
        }
        queued += frames
        player.scheduleBuffer(buffer) { [weak self] in
            Task { @MainActor in self?.queued -= frames }
        }
        if !player.isPlaying, queued >= Int(rate * 0.08) { player.play() }
    }

    func stop() {
        guard format != nil else { return }
        player.stop()
        engine.stop()
        format = nil
        queued = 0
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func format(rate: Double) -> AVAudioFormat? {
        if let format, format.sampleRate == rate { return format }
        stop()
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2) else { return nil }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
            if player.engine == nil { engine.attach(player) }
            engine.connect(player, to: engine.mainMixerNode, format: format)
            try engine.start()
        } catch {
            return nil
        }
        self.format = format
        return format
    }
}
