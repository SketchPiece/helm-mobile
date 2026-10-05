import SwiftUI

/// The microphone that sits where "send" goes while the field is empty.
/// Hold (≥0.3 s): record, release to send, slide left past the threshold to cancel.
/// Tap: hands-free dictation that ends with ✓ and lands in the field for editing.
struct MicButton: View {
    let voice: VoiceInput
    let onHoldStart: () -> Void
    let onHoldEnd: (_ cancelled: Bool) -> Void
    let onTap: () -> Void
    @Binding var dragOffset: CGFloat
    /// Amber, in the action slot while there is nothing to send. Otherwise a quiet icon beside
    /// send or stop, so dictation is still one tap away.
    var prominent = true

    @State private var pressedAt: Date?
    @State private var holding = false
    static let cancelThreshold: CGFloat = -72

    var body: some View {
        let recordingHold = voice.state == .recording(handsFree: false)
        Image(systemName: prominent || recordingHold ? "mic.fill" : "mic")
            .font(.system(size: prominent ? 17 : 16, weight: .semibold))
            .frame(width: prominent ? 40 : 34, height: prominent ? 40 : 34)
            .foregroundStyle(recordingHold ? .white : prominent ? Palette.accentForeground : Palette.textMuted)
            .background(recordingHold ? Palette.error : prominent ? Palette.accent : .clear, in: .circle)
            .scaleEffect(recordingHold ? 1.25 : 1)
            .animation(.easeOut(duration: 0.15), value: recordingHold)
            .contentShape(.circle)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if pressedAt == nil {
                            pressedAt = Date()
                            let started = pressedAt
                            Task {
                                try? await Task.sleep(for: .milliseconds(300))
                                if pressedAt == started, pressedAt != nil {
                                    holding = true
                                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                    onHoldStart()
                                }
                            }
                        }
                        dragOffset = min(0, value.translation.width)
                    }
                    .onEnded { _ in
                        let wasHolding = holding
                        let cancelled = dragOffset < Self.cancelThreshold
                        pressedAt = nil
                        holding = false
                        dragOffset = 0
                        if wasHolding {
                            onHoldEnd(cancelled)
                        } else {
                            onTap()
                        }
                    }
            )
            .accessibilityLabel("Dictate")
            .accessibilityHint("Hold to talk, release to send")
            .accessibilityAction { onTap() }
    }
}

/// Replaces the text field while recording, transcribing, or after a failed transcription.
struct VoiceStrip: View {
    let voice: VoiceInput
    let dragOffset: CGFloat
    let onCancel: () -> Void
    let onDone: () -> Void
    let onRetry: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            switch voice.state {
            case .recording(let handsFree):
                let cancelling = dragOffset < MicButton.cancelThreshold
                if handsFree {
                    Button(action: onCancel) {
                        Image(systemName: "xmark").font(.system(size: 14, weight: .semibold)).frame(width: 32, height: 32)
                    }
                    .foregroundStyle(Palette.textMuted)
                }
                Circle().fill(Palette.error).frame(width: 8, height: 8)
                if let startedAt = voice.startedAt {
                    Text(startedAt, style: .timer)
                        .font(Typography.mono(14))
                        .foregroundStyle(Palette.text)
                        .monospacedDigit()
                }
                if handsFree {
                    LevelBars(levels: voice.levels)
                    Button(action: onDone) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 15, weight: .bold))
                            .frame(width: 36, height: 36)
                            .foregroundStyle(Palette.accentForeground)
                            .background(Palette.accent, in: .circle)
                    }
                } else {
                    Text(cancelling ? String(localized: "Release to cancel") : String(localized: "Release to send · slide left to cancel"))
                        .font(Typography.footnote)
                        .foregroundStyle(cancelling ? Palette.errorText : Palette.textMuted)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .offset(x: max(dragOffset * 0.4, -40))
                    Spacer(minLength: 0)
                }
            case .transcribing:
                ProgressView().controlSize(.small)
                Text("Transcribing…").font(Typography.subheadline).foregroundStyle(Palette.textMuted)
                Spacer(minLength: 0)
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.errorText)
                Text(message).font(Typography.footnote).foregroundStyle(Palette.text).lineLimit(2)
                Spacer(minLength: 0)
                Button("Retry", action: onRetry)
                    .font(Typography.footnote.weight(.semibold))
                    .foregroundStyle(Palette.accentText)
                Button(action: onCancel) {
                    Image(systemName: "xmark").font(.system(size: 13, weight: .semibold)).frame(width: 28, height: 28)
                }
                .foregroundStyle(Palette.textMuted)
            case .idle:
                EmptyView()
            }
        }
        .frame(minHeight: 36)
        .padding(.leading, 6)
    }
}

/// A static bar chart of recent input levels (redrawn only when a new sample arrives).
struct LevelBars: View {
    let levels: [Double]

    var body: some View {
        Canvas { context, size in
            let count = 24
            let samples = Array(levels.suffix(count))
            let barWidth: CGFloat = 3
            let gap = (size.width - CGFloat(count) * barWidth) / CGFloat(count - 1)
            for index in 0..<count {
                let sampleIndex = index - (count - samples.count)
                let value = sampleIndex >= 0 ? samples[sampleIndex] : 0
                let height = max(3, CGFloat(value) * size.height)
                let rect = CGRect(x: CGFloat(index) * (barWidth + gap), y: (size.height - height) / 2, width: barWidth, height: height)
                context.fill(Path(roundedRect: rect, cornerRadius: 1.5), with: .color(Palette.textMuted))
            }
        }
        .frame(height: 22)
        .frame(maxWidth: .infinity)
    }
}

extension View {
    /// Folds the composer's text view away while the voice strip shows, without taking it out of
    /// the window: removing it would resign first responder and drop the keyboard.
    func voiceCollapsed(_ collapsed: Bool) -> some View {
        frame(height: collapsed ? 0 : nil)
            .clipped()
            .opacity(collapsed ? 0 : 1)
            .allowsHitTesting(!collapsed)
            .accessibilityHidden(collapsed)
    }
}
