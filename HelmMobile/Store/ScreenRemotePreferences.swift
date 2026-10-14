import SwiftUI

/// How the computer's screen sits on the phone's when it opens (and when it switches displays).
enum ScreenOpenZoom: String, CaseIterable, Identifiable {
    case fill, fit, actual
    var id: String { rawValue }

    var title: String {
        switch self {
        case .fill: String(localized: "Zoomed in")
        case .fit: String(localized: "Whole screen")
        case .actual: String(localized: "Actual size")
        }
    }

    var detail: String {
        switch self {
        case .fill: String(localized: "The screen covers the phone's; the view follows the cursor.")
        case .fit: String(localized: "All of the computer's screen at once, small on a phone.")
        case .actual: String(localized: "A point on the computer is a point here, as on its own screen.")
        }
    }
}

/// Which of the computer's displays the screen opens on.
enum ScreenDisplayChoice: String, CaseIterable, Identifiable {
    case main, virtual, all
    var id: String { rawValue }

    /// The separate display is the iPad's own size; on a phone it would be a sliver.
    @MainActor static var available: [ScreenDisplayChoice] {
        UIDevice.current.userInterfaceIdiom == .pad ? allCases : [.main, .all]
    }

    /// What's used: the separate display falls back to the main one off an iPad.
    @MainActor static var current: ScreenDisplayChoice {
        let stored = UserDefaults.standard.string(forKey: PhonePreferences.screenDisplayKey)
            .flatMap(ScreenDisplayChoice.init(rawValue:)) ?? .main
        return available.contains(stored) ? stored : .main
    }

    var title: String {
        switch self {
        case .main: String(localized: "Main display")
        case .virtual: String(localized: "Separate display")
        case .all: String(localized: "All displays")
        }
    }

    var detail: String {
        switch self {
        case .main: String(localized: "The display with the menu bar.")
        case .virtual: String(localized: "The computer adds a display the size of this iPad, sharp at its own resolution. Move windows to it; when you close the screen, they go back to the others.")
        case .all: String(localized: "Every display side by side, as they're arranged, so you can drag a window from one to another.")
        }
    }
}

/// The separate display's size: the iPad's own, or more room at a smaller scale.
enum ScreenVirtualSize: String, CaseIterable, Identifiable {
    case same, more, most
    var id: String { rawValue }

    var scale: CGFloat {
        switch self {
        case .same: 1
        case .more: 1.25
        case .most: 1.5
        }
    }

    var title: String {
        switch self {
        case .same: String(localized: "Same as this iPad")
        case .more: String(localized: "More space")
        case .most: String(localized: "Most space")
        }
    }

    var detail: String {
        switch self {
        case .same: String(localized: "Text and buttons the size of the iPad's own.")
        case .more: String(localized: "A quarter more room, everything a little smaller.")
        case .most: String(localized: "Half again the room, everything smaller.")
        }
    }
}

/// How much picture goes over the network.
enum ScreenQuality: String, CaseIterable, Identifiable {
    case sharp, balanced, saver
    var id: String { rawValue }

    /// The video's widest side in pixels, its bit rate and frame rate.
    var stream: (maxWidth: Int, bitrate: Int, fps: Int) {
        switch self {
        // Twice the points: zooming in stays sharp up to Retina, capped for the network.
        case .sharp: (3024, 8_000_000, 30)
        case .balanced: (1920, 4_000_000, 30)
        case .saver: (1280, 1_500_000, 20)
        }
    }

    var title: String {
        switch self {
        case .sharp: String(localized: "Sharp")
        case .balanced: String(localized: "Balanced")
        case .saver: String(localized: "Data saver")
        }
    }

    var detail: String {
        switch self {
        case .sharp: String(localized: "Full resolution. Best on Wi-Fi.")
        case .balanced: String(localized: "Softer when zoomed in, half the data.")
        case .saver: String(localized: "For a cellular connection: blurrier and fewer frames.")
        }
    }
}

/// How long the separate display stays once the screen is closed (the app goes to the
/// background, the iPad locks), so a quick trip away finds the windows where they were.
enum ScreenKeepDisplay: String, CaseIterable, Identifiable {
    case never, short, long
    var id: String { rawValue }

    var seconds: Int {
        switch self {
        case .never: 0
        case .short: 120
        case .long: 600
        }
    }

    var title: String {
        switch self {
        case .never: String(localized: "Right away")
        case .short: String(localized: "After 2 minutes")
        case .long: String(localized: "After 10 minutes")
        }
    }

    var detail: String {
        switch self {
        case .never: String(localized: "Its windows go back to the computer's displays as soon as the screen closes.")
        case .short: String(localized: "Locking the iPad or a quick look at another app keeps the windows in place.")
        case .long: String(localized: "For longer breaks. Until then, its windows aren't seen on the computer.")
        }
    }
}

/// How far the cursor goes for a finger's or a trackpad's move.
enum ScreenCursorSpeed: String, CaseIterable, Identifiable {
    case slow, normal, fast
    var id: String { rawValue }

    var factor: CGFloat {
        switch self {
        case .slow: 0.7
        case .normal: 1
        case .fast: 1.5
        }
    }

    var title: String {
        switch self {
        case .slow: String(localized: "Slow")
        case .normal: String(localized: "Normal")
        case .fast: String(localized: "Fast")
        }
    }
}
