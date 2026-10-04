import SwiftUI

/// Settings → Follow-ups: what sending does while the agent is working.
struct FollowUpSettingsView: View {
    @AppStorage(PhonePreferences.followUpKey) private var behavior = FollowUpBehavior.queue

    var body: some View {
        ChoiceForm(title: String(localized: "Follow-ups"), header: String(localized: "While the agent is working"),
                   options: FollowUpBehavior.allCases, selection: $behavior, label: \.title, detail: \.detail,
                   footer: String(localized: "Long-press the send button to use the other option for one message. With a hardware keyboard, Command-Return does the same."))
    }
}

/// Settings → Keyboard: Return sends or inserts a new line.
struct KeyboardSettingsView: View {
    @AppStorage(PhonePreferences.returnKeyKey) private var behavior = ReturnKeyBehavior.newline

    var body: some View {
        ChoiceForm(title: String(localized: "Keyboard"), header: String(localized: "Return key"),
                   options: ReturnKeyBehavior.allCases, selection: $behavior, label: \.title, detail: \.detail,
                   footer: String(localized: "Applies to the on-screen keyboard and a hardware keyboard."))
    }
}

/// Settings → Code and diffs: a fixed code size instead of Dynamic Type's, and wrapping long
/// lines in code blocks instead of scrolling them sideways.
struct CodeSettingsView: View {
    @AppStorage(PhonePreferences.codeFontSizeKey) private var fontSize = 0
    @AppStorage(PhonePreferences.codeWordWrapKey) private var wordWrap = false

    private var appearance: CodeAppearance { CodeAppearance(fontSize: fontSize, wordWrap: wordWrap) }

    var body: some View {
        Form {
            Section {
                MarkdownView(text: "```swift\nlet greeting = \"Hello from Helm\" // a long line shows how code wraps or scrolls\nprint(greeting)\n```")
                    .environment(\.codeAppearance, appearance)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
            }
            Section {
                Toggle("Custom font size", isOn: Binding(
                    get: { appearance.fontSize != nil },
                    set: { fontSize = $0 ? Int(PhonePreferences.defaultCodeFontSize) : 0 }
                ))
                .accessibilityIdentifier("customCodeSize")
                if let size = appearance.fontSize {
                    Stepper(value: Binding(get: { Int(size) }, set: { fontSize = $0 }), in: PhonePreferences.codeFontSizes) {
                        HStack {
                            Text("Font size")
                            Spacer()
                            Text("\(Int(size)) pt").foregroundStyle(Palette.textMuted).monospacedDigit()
                        }
                    }
                }
                Toggle("Wrap long lines", isOn: $wordWrap)
                    .accessibilityIdentifier("codeWordWrap")
            } footer: {
                Text("Code blocks and diffs follow the phone's text size unless you set one here. Diffs always scroll sideways.")
                    .font(Typography.footnote)
            }
            .tint(Palette.accent)
        }
        .font(Typography.body)
        .scrollContentBackground(.hidden)
        .background(Palette.canvas)
        .navigationTitle("Code and diffs")
        .navigationBarTitleDisplayMode(.inline)
    }
}

extension CodeAppearance {
    /// The value shown on the settings row.
    var summary: String {
        fontSize.map { String(localized: "\(Int($0)) pt") } ?? String(localized: "Automatic")
    }
}

/// A single-choice list with a description per option, as the RN settings screens draw them.
private struct ChoiceForm<Option: Hashable & Identifiable>: View {
    let title: String
    let header: String
    let options: [Option]
    @Binding var selection: Option
    let label: KeyPath<Option, String>
    let detail: KeyPath<Option, String>
    let footer: String

    var body: some View {
        Form {
            Section {
                ForEach(options) { option in
                    Button {
                        selection = option
                        UISelectionFeedbackGenerator().selectionChanged()
                    } label: {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(option[keyPath: label]).font(Typography.body).foregroundStyle(Palette.text)
                                Text(option[keyPath: detail]).font(Typography.footnote).foregroundStyle(Palette.textMuted)
                            }
                            Spacer()
                            if selection == option {
                                Image(systemName: "checkmark").foregroundStyle(Palette.accentText)
                            }
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selection == option ? .isSelected : [])
                }
            } header: {
                Text(header).sectionLabelStyle()
            } footer: {
                Text(footer).font(Typography.footnote)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Palette.canvas)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
