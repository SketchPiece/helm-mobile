import SwiftUI

/// Preferences that belong to this phone rather than a Mac (RN keeps them in its device
/// preference blob). Views read them with `@AppStorage(PhonePreferences.…)`.
enum PhonePreferences {
    static let followUpKey = "followUpBehavior"
    static let returnKeyKey = "composerReturnKey"
    static let afterStartKey = "newThreadAfterStart"
    /// 0 means automatic: code follows Dynamic Type.
    static let codeFontSizeKey = "codeFontSize"
    static let codeWordWrapKey = "codeWordWrap"

    static let codeFontSizes = 8...18
    /// Code's size at the default Dynamic Type setting.
    static let defaultCodeFontSize: CGFloat = 13
}

/// What the send button does while a turn is running: queue waits for the turn to finish,
/// steer interrupts it with the new message. Long-press offers the other one.
enum FollowUpBehavior: String, CaseIterable, Identifiable {
    case queue, steer
    var id: String { rawValue }

    var other: FollowUpBehavior { self == .queue ? .steer : .queue }

    var followUp: ThreadSession.FollowUp { self == .queue ? .queue : .steer }

    var title: String {
        switch self {
        case .queue: String(localized: "Queue")
        case .steer: String(localized: "Steer")
        }
    }

    var detail: String {
        switch self {
        case .queue: String(localized: "Your message waits and runs after the current turn finishes.")
        case .steer: String(localized: "Your message reaches the agent right away, changing what it is working on.")
        }
    }
}

/// What happens once a thread starts. It always opens first; the other two move on by themselves once
/// the agent is at work: to New Thread in the same project, or back to the thread list.
enum AfterStartBehavior: String, CaseIterable, Identifiable {
    case open, another, home
    var id: String { rawValue }

    var title: String {
        switch self {
        case .open: String(localized: "Open the thread")
        case .another: String(localized: "Start another")
        case .home: String(localized: "Back to threads")
        }
    }

    var detail: String {
        switch self {
        case .open: String(localized: "The new thread opens, so you can follow the agent.")
        case .another: String(localized: "Once the agent is at work, New Thread opens in the same project for the next task.")
        case .home: String(localized: "Once the agent is at work, you're back on the thread list.")
        }
    }
}

/// What Return does in the composer, on the on-screen keyboard and a hardware one.
enum ReturnKeyBehavior: String, CaseIterable, Identifiable {
    case send, newline
    var id: String { rawValue }

    var title: String {
        switch self {
        case .send: String(localized: "Send message")
        case .newline: String(localized: "Insert new line")
        }
    }

    var detail: String {
        switch self {
        case .send: String(localized: "Return sends the message. Shift-Return inserts a new line.")
        case .newline: String(localized: "Return inserts a new line. Command-Return sends the message.")
        }
    }
}

/// Code blocks and diffs: a fixed size when the user picked one, else Dynamic Type's.
struct CodeAppearance: Equatable {
    /// nil follows Dynamic Type.
    var fontSize: CGFloat?
    var wordWrap: Bool

    init(fontSize: Int, wordWrap: Bool) {
        self.fontSize = PhonePreferences.codeFontSizes.contains(fontSize) ? CGFloat(fontSize) : nil
        self.wordWrap = wordWrap
    }

    /// IBM Plex Mono at the chosen size, else `automatic` scaled with Dynamic Type.
    func font(automatic: CGFloat = PhonePreferences.defaultCodeFontSize) -> Font {
        if let fontSize { return .custom("IBMPlexMono-Regular", fixedSize: fontSize) }
        return Typography.mono(automatic)
    }
}

extension EnvironmentValues {
    /// Set once at the root from `@AppStorage`, read by code blocks and the diff viewer.
    @Entry var codeAppearance = CodeAppearance(fontSize: 0, wordWrap: false)
}
