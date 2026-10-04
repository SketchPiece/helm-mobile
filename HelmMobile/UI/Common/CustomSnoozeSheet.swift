import SwiftUI

/// "Snooze → Custom…", like the desktop's custom snooze dialog: a date and time, or a duration
/// from now. Stays open with the server's reason if Helm refuses (a thread waiting on you or
/// with queued messages can't be snoozed).
struct CustomSnoozeSheet: View {
    let snooze: (Date) async throws -> Void
    @Environment(\.dismiss) private var dismiss

    private enum Mode: Hashable { case date, duration }

    @State private var mode = Mode.date
    @State private var day = Date().addingTimeInterval(3600)
    @State private var time = Date().addingTimeInterval(3600)
    @State private var amount = "2"
    @State private var unit = Snooze.DurationUnit.hours
    @State private var sending = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Schedule type", selection: $mode) {
                        Text("Date and time").tag(Mode.date)
                        Text("Duration").tag(Mode.duration)
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
                Section {
                    if mode == .date {
                        DatePicker("Date", selection: $day, in: Calendar.current.startOfDay(for: Date())..., displayedComponents: .date)
                        DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute)
                    } else {
                        HStack {
                            Text("Snooze for")
                            Spacer()
                            TextField("2", text: $amount)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .frame(maxWidth: 80)
                                .accessibilityIdentifier("snoozeAmount")
                            Stepper("Snooze for", value: Binding(
                                get: { Double(amount.replacingOccurrences(of: ",", with: ".")) ?? 0 },
                                set: { amount = $0.formatted(.number.grouping(.never)) }
                            ), in: 1...999, step: 1)
                            .labelsHidden()
                        }
                        Picker("Unit", selection: $unit) {
                            ForEach(Snooze.DurationUnit.allCases) { Text($0.title).tag($0) }
                        }
                    }
                } header: {
                    Text("Choose when the thread comes back to your list.")
                        .font(Typography.footnote)
                        .textCase(nil)
                } footer: {
                    if let error {
                        Text(error).font(Typography.footnote).foregroundStyle(Palette.errorText)
                    } else if let wake {
                        Text("Wakes \(Snooze.wakeDescription(until: wake))").font(Typography.footnote)
                    }
                }
            }
            .tint(Palette.text)
            .font(Typography.body)
            .scrollContentBackground(.hidden)
            .background(Palette.canvas)
            .navigationTitle("Custom snooze")
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: mode) { error = nil }
            .onChange(of: amount) { error = nil }
            .onChange(of: day) { error = nil }
            .onChange(of: time) { error = nil }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .close) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        submit()
                    } label: {
                        if sending { ProgressView() } else { Text("Snooze") }
                    }
                    .disabled(sending)
                    .accessibilityIdentifier("confirmSnooze")
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var input: Snooze.CustomInput {
        mode == .date ? .date(day: day, time: time) : .duration(amount: amount, unit: unit)
    }

    private var wake: Date? { Snooze.resolveCustom(input) }

    private func submit() {
        guard let wake else {
            error = mode == .date
                ? String(localized: "Choose a valid date and time in the future.")
                : String(localized: "Enter a positive duration.")
            return
        }
        sending = true
        error = nil
        Task {
            do {
                try await snooze(wake)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            sending = false
        }
    }
}

/// The "Snooze" submenu: the shared presets, each with its wake time, then "Custom…".
/// Presets are computed when the menu opens, so "This evening" disappears on time.
struct SnoozeMenu: View {
    let snooze: (Date) -> Void
    let custom: () -> Void

    var body: some View {
        Menu {
            ForEach(Snooze.presets()) { preset in
                Button {
                    snooze(preset.date)
                } label: {
                    Text(preset.title)
                    Text(preset.whenLabel)
                }
            }
            Button("Custom…", action: custom)
        } label: {
            Label("Snooze", systemImage: "moon.zzz")
        }
    }
}

/// The swipe's "Snooze": a short bottom sheet with the presets and their wake times, then
/// "Custom…". Stays open with Helm's reason if it refuses.
struct SnoozeChooserSheet: View {
    let threadTitle: String
    let snooze: (Date) async throws -> Void
    let custom: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var presets = Snooze.presets()
    @State private var sending: Snooze.Preset.Kind?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Snooze until").font(Typography.headline).foregroundStyle(Palette.text)
                Text(threadTitle).font(Typography.footnote).foregroundStyle(Palette.textMuted).lineLimit(1)
            }
            .padding(.horizontal, 20)
            .padding(.top, 22)
            .padding(.bottom, 12)

            VStack(spacing: 0) {
                ForEach(presets) { preset in
                    row(symbol: symbol(preset.kind), title: preset.title, detail: preset.whenLabel,
                        busy: sending == preset.kind) {
                        choose(preset)
                    }
                    Divider().padding(.leading, 52)
                }
                row(symbol: "calendar", title: String(localized: "Custom…"), detail: nil, busy: false) {
                    dismiss()
                    custom()
                }
            }
            .background(Palette.surface, in: .rect(cornerRadius: 18, style: .continuous))
            .padding(.horizontal, 16)

            if let error {
                Text(error)
                    .font(Typography.footnote)
                    .foregroundStyle(Palette.errorText)
                    .padding(.horizontal, 20)
                    .padding(.top, 10)
            }
            Spacer(minLength: 0)
        }
        .background(Palette.canvas)
        .presentationDetents([.height(CGFloat(presets.count + 1) * 52 + 110 + (error == nil ? 0 : 40))])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(28)
    }

    private func row(symbol: String, title: String, detail: String?, busy: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(Palette.textMuted)
                    .frame(width: 24)
                Text(title).font(Typography.body).foregroundStyle(Palette.text)
                Spacer()
                if busy {
                    ProgressView()
                } else if let detail {
                    Text(detail).font(Typography.subheadline).foregroundStyle(Palette.textMuted).monospacedDigit()
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 52)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(sending != nil)
    }

    private func symbol(_ kind: Snooze.Preset.Kind) -> String {
        switch kind {
        case .hour: "clock"
        case .threeHours: "clock.arrow.circlepath"
        case .evening: "moon"
        case .tomorrow: "sunrise"
        case .nextWeek: "calendar.badge.clock"
        }
    }

    private func choose(_ preset: Snooze.Preset) {
        sending = preset.kind
        error = nil
        Task {
            do {
                try await snooze(preset.date)
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            sending = nil
        }
    }
}
