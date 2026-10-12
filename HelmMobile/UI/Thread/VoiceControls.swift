import SwiftUI

/// The microphone that sits where "send" goes while the field is empty.
/// Recording starts and shows at touch-down. Hold (≥0.3 s): release to send, slide left past the
/// threshold to cancel. Tap: the same recording goes on hands-free, ends with ✓ and lands in the
/// field for editing.
struct MicButton: View {
    let voice: VoiceInput
    let onHoldEnd: (_ cancelled: Bool) -> Void
    /// Touch-down, before hold or tap is known: start recording so nothing waits.
    let onPress: () -> Void
    /// Released before it became a hold: keep recording hands-free.
    let onTap: () -> Void
    /// The touch ended as neither (the system cancelled it early): drop what onPress started.
    let onAbandon: () -> Void
    @Binding var dragOffset: CGFloat
    /// Amber, in the action slot while there is nothing to send. Otherwise a quiet icon beside
    /// send or stop, so dictation is still one tap away.
    var prominent = true

    @State private var pressedAt: Date?
    @State private var holding = false
    static let cancelThreshold: CGFloat = -72
    private var touchInset: CGFloat { prominent ? 4 : 5 }

    var body: some View {
        let recordingHold = voice.state == .recording(handsFree: false)
        let cancelling = recordingHold && dragOffset < Self.cancelThreshold
        Image(systemName: cancelling ? "xmark" : prominent || recordingHold ? "mic.fill" : "mic")
            // A crossfade: .replace shrinks the old symbol to a dot before the new one grows.
            .contentTransition(.opacity)
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
            // A 48pt square to touch (44 for the quiet icon), wider than the circle drawn: a
            // slightly-off press otherwise lands on the card and opens the keyboard instead.
            .padding(touchInset)
            .contentShape(.rect)
            // A UIKit recognizer, not a SwiftUI gesture: by the home indicator SwiftUI held the
            // touch ~0.8 s for the system's swipe home, where UIKit has it within a frame or two.
            .gesture(MicPressGesture(
                onBegan: press,
                onMoved: { dragOffset = min(0, $0) },
                // A touch the system took away (another gesture won) ends the hold as a release,
                // sending what was said, but doesn't count as a tap.
                onEnded: { cancelledBySystem in
                    release(cancelledByUser: dragOffset < Self.cancelThreshold, tapped: !cancelledBySystem)
                }
            ))
            .padding(-touchInset)
            .onDisappear {
                if pressedAt != nil { release(cancelledByUser: false, tapped: false) }
            }
            .accessibilityLabel("Dictate")
            .accessibilityHint("Hold to talk, release to send")
            .accessibilityAction { onPress(); onTap() }
    }

    private func press() {
        guard pressedAt == nil else { return }
        pressedAt = Date()
        onPress()
        let started = pressedAt
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            if pressedAt == started, pressedAt != nil {
                holding = true
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            }
        }
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

/// One finger on a microphone (the composer's, the Mac remote's), reported straight from the touches: the press as it lands, the
/// horizontal slide, and the lift (or the system taking the touch away).
struct MicPressGesture: UIGestureRecognizerRepresentable {
    let onBegan: () -> Void
    let onMoved: (CGFloat) -> Void
    let onEnded: (_ cancelledBySystem: Bool) -> Void

    func makeUIGestureRecognizer(context: Context) -> MicPressRecognizer { MicPressRecognizer() }

    func updateUIGestureRecognizer(_ recognizer: MicPressRecognizer, context: Context) {
        recognizer.onBegan = onBegan
        recognizer.onMoved = onMoved
        recognizer.onEnded = onEnded
    }
}

final class MicPressRecognizer: UIGestureRecognizer {
    var onBegan: () -> Void = {}
    var onMoved: (CGFloat) -> Void = { _ in }
    var onEnded: (Bool) -> Void = { _ in }
    private var touch: UITouch?
    private var startX: CGFloat = 0

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        delaysTouchesBegan = false
    }

    // The callbacks run from the touches themselves: a state change can wait on other recognizers
    // (the system's among them), the touches don't.
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard self.touch == nil, let touch = touches.first else {
            touches.forEach { ignore($0, for: event) }
            return
        }
        self.touch = touch
        startX = touch.location(in: nil).x
        state = .began
        onBegan()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch, touches.contains(touch) else { return }
        onMoved(touch.location(in: nil).x - startX)
        state = .changed
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch, touches.contains(touch) else { return }
        self.touch = nil
        state = .ended
        onEnded(false)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch, touches.contains(touch) else { return }
        self.touch = nil
        state = .cancelled
        onEnded(true)
    }

    override func reset() {
        super.reset()
        if touch != nil {
            touch = nil
            onEnded(true)
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
        // text view, and the keyboard drops. Width stays, or the text reflows as it folds.
        frame(height: collapsed ? 0 : nil)
            .clipped()
            .accessibilityHidden(collapsed)
    }
}
