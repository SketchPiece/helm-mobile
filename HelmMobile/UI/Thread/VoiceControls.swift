import SwiftUI

/// The microphone that sits where "send" goes while the field is empty.
/// Hold (≥0.3 s): record, release to send, slide left past the threshold to cancel.
/// Tap: hands-free dictation that ends with ✓ and lands in the field for editing.
struct MicButton: View {
    let voice: VoiceInput
    let onHoldStart: () -> Void
    let onHoldEnd: (_ cancelled: Bool) -> Void
    let onTap: () -> Void
    /// Touch-down, before hold or tap is known: start the microphone so nothing waits.
    var onPress: () -> Void = {}
    /// The touch ended as neither (the system cancelled it early): drop what onPress started.
    var onAbandon: () -> Void = {}
    @Binding var dragOffset: CGFloat
    /// Amber, in the action slot while there is nothing to send. Otherwise a quiet icon beside
    /// send or stop, so dictation is still one tap away.
    var prominent = true

    @State private var pressedAt: Date?
    @State private var holding = false
    /// True while a finger is down. Unlike `onEnded`, it also resets when the system cancels the
    /// touch (another gesture takes over), so a hold can never be left recording with no finger.
    @GestureState private var touching = false
    static let cancelThreshold: CGFloat = -72

    var body: some View {
        let recordingHold = voice.state == .recording(handsFree: false)
        let cancelling = recordingHold && dragOffset < Self.cancelThreshold
        Image(systemName: cancelling ? "xmark" : prominent || recordingHold ? "mic.fill" : "mic")
            .contentTransition(.symbolEffect(.replace))
            .font(.system(size: prominent ? 17 : 16, weight: .semibold))
            .frame(width: prominent ? 40 : 34, height: prominent ? 40 : 34)
            .foregroundStyle(recordingHold ? .white : prominent ? Palette.accentForeground : Palette.textMuted)
            .background(recordingHold ? Palette.error : prominent ? Palette.accent : .clear, in: .circle)
            // Swells a little under the finger, staying inside the card.
            // Answers the touch at once (a press-in), before recording shows.
            .scaleEffect(recordingHold ? 1.1 : pressedAt != nil ? 0.9 : 1)
            .animation(.easeOut(duration: 0.15), value: recordingHold)
            .animation(.spring(response: 0.3, dampingFraction: 0.85), value: cancelling)
            .sensoryFeedback(.impact(weight: .light), trigger: cancelling)
            .animation(.easeOut(duration: 0.1), value: pressedAt != nil)
            .contentShape(.circle)
            // Ahead of the glass card's own touch handling around it.
            .highPriorityGesture(
                DragGesture(minimumDistance: 0)
                    .updating($touching) { _, touching, _ in touching = true }
                    .onChanged { value in
                        if pressedAt == nil {
                            pressedAt = Date()
                            onPress()
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
                    .onEnded { _ in release(cancelledByUser: dragOffset < Self.cancelThreshold, tapped: true) }
            )
            // The touch went away without onEnded: the system cancelled it. End the hold as a
            // release (sending what was said), but don't count it as a tap.
            .onChange(of: touching) { _, touching in
                if !touching, pressedAt != nil { release(cancelledByUser: dragOffset < Self.cancelThreshold, tapped: false) }
            }
            .onDisappear {
                if pressedAt != nil { release(cancelledByUser: false, tapped: false) }
            }
            .accessibilityLabel("Dictate")
            .accessibilityHint("Hold to talk, release to send")
            .accessibilityAction { onTap() }
    }

    private func release(cancelledByUser: Bool, tapped: Bool) {
        guard pressedAt != nil else { return }
        let wasHolding = holding
        pressedAt = nil
        holding = false
        dragOffset = 0
        if wasHolding {
            onHoldEnd(cancelledByUser)
        } else if tapped {
            onTap()
        } else {
            onAbandon()
        }
    }
}

/// Takes the place of the composer's controls row while dictating: the card shows the recording
/// and nothing else. The action for it (the held microphone, or ✓ when hands-free) stays in the
/// amber slot beside it, so nothing moves under the finger.
struct VoiceStrip: View {
    let voice: VoiceInput
    let dragOffset: CGFloat
    let onCancel: () -> Void
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
                    .accessibilityLabel("Cancel dictation")
                }
                Circle().fill(Palette.error).frame(width: 8, height: 8)
                if let startedAt = voice.startedAt {
                    Text(startedAt, style: .timer)
                        .font(Typography.mono(14))
                        .foregroundStyle(Palette.text)
                        .monospacedDigit()
                }
                // How far the slide to cancel has gone, 0...1. Everything eases with it: the bars
                // fade, the hint follows the finger and reddens, then "Release to cancel" takes over.
                let progress = min(1, max(0, dragOffset / MicButton.cancelThreshold))
                ZStack(alignment: .leading) {
                    HStack(spacing: 0) {
                        LevelBars(levels: voice.levels)
                            .opacity(1 - progress * 0.75)
                            .padding(.trailing, 10)
                        if !handsFree {
                            Label("Cancel", systemImage: "chevron.left")
                                .labelStyle(.titleAndIcon)
                                .font(Typography.footnote)
                                .foregroundStyle(Palette.textMuted.mix(with: Palette.errorText, by: progress))
                                .lineLimit(1)
                                .fixedSize()
                            // Room opening behind the hint as it follows the finger: the bars
                            // narrow instead of being covered.
                            Color.clear.frame(width: min(-dragOffset * 0.5, 48), height: 0)
                        }
                    }
                    .opacity(cancelling ? 0 : 1)
                    .blur(radius: cancelling ? 4 : 0)
                    Label("Release to cancel", systemImage: "xmark")
                        .labelStyle(.titleAndIcon)
                        .font(Typography.footnote.weight(.medium))
                        .foregroundStyle(Palette.errorText)
                        .lineLimit(1)
                        .opacity(cancelling ? 1 : 0)
                        .blur(radius: cancelling ? 0 : 4)
                        .offset(x: cancelling ? 0 : 16)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .animation(.spring(response: 0.3, dampingFraction: 0.85), value: cancelling)
            case .transcribing:
                // The spinner is in the amber slot; one is enough.
                Text("Transcribing…").font(Typography.subheadline).foregroundStyle(Palette.textMuted)
                    .padding(.leading, 6)
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
        .frame(minHeight: 40)
        .padding(.leading, 6)
        .padding(.trailing, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The amber slot while dictating hands-free (✓ puts the text in the field) or transcribing.
struct VoiceSlotButton: View {
    let voice: VoiceInput
    let onDone: () -> Void

    var body: some View {
        switch voice.state {
        case .recording(handsFree: true):
            Button(action: onDone) {
                Image(systemName: "checkmark")
                    .font(.system(size: 16, weight: .bold))
                    .frame(width: 40, height: 40)
                    .foregroundStyle(Palette.accentForeground)
                    .background(Palette.accent, in: .circle)
            }
            .accessibilityLabel("Done dictating")
        case .transcribing:
            ProgressView()
                .tint(Palette.accentForeground)
                .frame(width: 40, height: 40)
                .background(Palette.accent.opacity(0.6), in: .circle)
        default:
            EmptyView()
        }
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
        .frame(height: 28)
        .frame(maxWidth: .infinity)
    }
}

extension View {
    /// Folds the composer's text view away while the voice strip shows, without taking it out of
    /// the window: removing it would resign first responder and drop the keyboard.
    func voiceCollapsed(_ collapsed: Bool) -> some View {
        // Height and clipping only: opacity 0 or allowsHitTesting(false) make UIKit resign the
        // text view, and the keyboard drops.
        frame(width: collapsed ? 0 : nil, height: collapsed ? 0 : nil)
            .clipped()
            .accessibilityHidden(collapsed)
    }
}
