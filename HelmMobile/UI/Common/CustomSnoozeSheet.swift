import SwiftUI

/// "Snooze → Custom…": pick a day and time. Stays open with the server's reason if Helm refuses
/// (a thread waiting on you or with queued messages can't be snoozed).
struct CustomSnoozeSheet: View {
    let snooze: (Date) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var date = SnoozePreset.tomorrowMorning.date()
    @State private var sending = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("Wake at", selection: $date, in: Date().addingTimeInterval(60)..., displayedComponents: [.date, .hourAndMinute])
                        .datePickerStyle(.graphical)
                        .tint(Palette.accent)
                } footer: {
                    if let error {
                        Text(error).font(Typography.footnote).foregroundStyle(Palette.errorText)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Palette.canvas)
            .navigationTitle("Snooze until")
            .navigationBarTitleDisplayMode(.inline)
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
        .presentationDetents([.large])
    }

    private func submit() {
        guard date > Date() else {
            error = String(localized: "Pick a time in the future.")
            return
        }
        sending = true
        error = nil
        Task {
            do {
                try await snooze(date)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            sending = false
        }
    }
}
