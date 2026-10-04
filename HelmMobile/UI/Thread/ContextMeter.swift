import SwiftUI

/// How full the agent's context window is: a small ring in the thread's top bar. Tapping it
/// shows the numbers and, when the provider can, compacts the conversation (`/compact`), as the
/// desktop composer's meter does.
struct ContextMeter: View {
    let used: Int
    let max: Int
    /// Why compacting isn't possible right now; nil when it is.
    let compactBlockedReason: String?
    /// Nil when the provider has no `/compact`.
    let compact: (() -> Void)?
    @State private var showing = false

    private var fraction: Double { min(1, Swift.max(0, Double(used) / Double(max))) }
    private var percent: String {
        let value = fraction * 100
        return value < 10 ? value.formatted(.number.precision(.fractionLength(0...1))) + "%" : "\(Int(value.rounded()))%"
    }
    private var color: Color { fraction > 0.9 ? Palette.errorText : fraction > 0.75 ? Palette.accentText : Palette.textMuted }

    var body: some View {
        Button {
            showing = true
        } label: {
            ZStack {
                Circle().stroke(Palette.textMuted.opacity(0.25), lineWidth: 2.5)
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(color, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 18, height: 18)
            .animation(.easeOut(duration: 0.5), value: fraction)
        }
        .accessibilityLabel(Text("Context window \(percent) used"))
        .accessibilityIdentifier("contextMeter")
        .popover(isPresented: $showing) {
            details
                .presentationCompactAdaptation(.popover)
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Context window").font(Typography.subheadline.weight(.semibold))
                Spacer(minLength: 16)
                Text("\(percent) · \(TokenCount.short(used)) / \(TokenCount.short(max))")
                    .font(Typography.footnote)
                    .monospacedDigit()
                    .foregroundStyle(Palette.textMuted)
            }
            ProgressView(value: fraction)
                .tint(color)
            if let compact {
                Button {
                    showing = false
                    compact()
                } label: {
                    Label("Compact context", systemImage: "arrow.down.right.and.arrow.up.left")
                        .font(Typography.subheadline.weight(.medium))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
                .disabled(compactBlockedReason != nil)
                .accessibilityIdentifier("compactContext")
                if let compactBlockedReason {
                    Text(compactBlockedReason)
                        .font(Typography.footnote)
                        .foregroundStyle(Palette.textMuted)
                }
            } else {
                Text("The agent compacts the conversation by itself when the window fills up.")
                    .font(Typography.footnote)
                    .foregroundStyle(Palette.textMuted)
            }
        }
        .padding(16)
        .frame(width: 280)
    }
}
