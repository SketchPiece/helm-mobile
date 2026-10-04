import SwiftUI

/// Above the composer when the latest run stopped on a usage limit: when the limit resets, and
/// what to do about it (resume by itself at reset, snooze until then, or continue right now).
struct UsageLimitCard: View {
    let state: UsageLimitRecoveryState
    let session: ThreadSession
    @State private var pending: Action?
    @State private var error: String?

    private enum Action { case autoResume, snooze, resume }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "gauge.with.dots.needle.100percent")
                    .foregroundStyle(Palette.accentText)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Usage limit reached")
                        .font(Typography.subheadline.weight(.semibold))
                        .foregroundStyle(Palette.text)
                    Text(resetText)
                        .font(Typography.footnote)
                        .foregroundStyle(Palette.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if state.canSchedule {
                Toggle(isOn: Binding(get: { state.autoResume }, set: { setAutoResume($0) })) {
                    Text("Resume automatically").font(Typography.subheadline)
                }
                .tint(Palette.working)
                .disabled(pending != nil)
            }
            HStack(spacing: 8) {
                if state.canSchedule {
                    Button { toggleSnooze() } label: {
                        label(state.snoozed ? String(localized: "Wake now") : String(localized: "Snooze until reset"), for: .snooze)
                            .font(Typography.subheadline.weight(.medium))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                    .disabled(pending != nil || (!state.snoozed && resetPassed))
                }
                Button { continueNow() } label: {
                    label(String(localized: "Continue now"), for: .resume)
                        .font(Typography.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .tint(Palette.accent)
                .foregroundStyle(Palette.accentForeground)
                .disabled(pending != nil)
                .accessibilityIdentifier("continueAfterLimit")
            }
            if let error {
                Text(error).font(Typography.footnote).foregroundStyle(Palette.errorText)
            }
        }
        .padding(14)
        .floatingSurface(cornerRadius: 18)
    }

    private var resetPassed: Bool { (state.resetDate ?? .distantPast) <= Date() }

    private var resetText: String {
        guard let reset = state.resetDate else {
            return String(localized: "The provider didn't say when it resets. Continue when your limit is back.")
        }
        let time = Calendar.current.isDateInToday(reset)
            ? reset.formatted(date: .omitted, time: .shortened)
            : reset.formatted(date: .abbreviated, time: .shortened)
        return String(localized: "Resets \(time)")
    }

    @ViewBuilder
    private func label(_ title: String, for action: Action) -> some View {
        if pending == action { ProgressView() } else { Text(title) }
    }

    private func setAutoResume(_ on: Bool) {
        guard let resetAt = state.resetAt else { return }
        run(.autoResume) { try await session.setLimitRecovery(runId: state.runId, resetAt: resetAt, autoResume: on) }
    }

    private func toggleSnooze() {
        guard let resetAt = state.resetAt else { return }
        if !state.snoozed, resetPassed {
            error = String(localized: "The reset time has passed. Continue the thread yourself.")
            return
        }
        run(.snooze) { try await session.setLimitRecovery(runId: state.runId, resetAt: resetAt, snooze: !state.snoozed) }
    }

    private func continueNow() {
        run(.resume) { try await session.continueAfterLimit(runId: state.runId) }
    }

    private func run(_ action: Action, _ work: @escaping () async throws -> Void) {
        pending = action
        error = nil
        Task {
            do {
                try await work()
                UISelectionFeedbackGenerator().selectionChanged()
            } catch {
                self.error = error.localizedDescription
            }
            pending = nil
        }
    }
}
