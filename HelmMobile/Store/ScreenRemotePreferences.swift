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

/// How many bits the picture gets, per 60 frames a second (120 gets twice as many), as Sill's
/// presets. HEVC keeps text sharp at these on Wi-Fi.
enum ScreenQuality: String, CaseIterable, Identifiable {
    case saver, balanced, high, max
    var id: String { rawValue }

    static let standard = ScreenQuality.balanced

    var megabitsPer60: Int {
        switch self {
        case .saver: 4
        case .balanced: 15
        case .high: 25
        case .max: 40
        }
    }

    var title: String {
        switch self {
        case .saver: String(localized: "Data saver")
        case .balanced: String(localized: "Balanced")
        case .high: String(localized: "High")
        case .max: String(localized: "Maximum")
        }
    }

    var detail: String {
        switch self {
        case .saver: String(localized: "For a cellular connection or a weak network: softer when things move.")
        case .balanced: String(localized: "Sharp text and smooth motion on Wi-Fi.")
        case .high: String(localized: "Crisper while scrolling and playing video.")
        case .max: String(localized: "As good as it gets, for a strong network.")
        }
    }
}

/// How often the picture changes, at most.
enum ScreenFrameRate: String, CaseIterable, Identifiable {
    case auto, sixty, thirty
    var id: String { rawValue }

    /// What's asked of the computer: the screen's own rate (120 with ProMotion), 60 in Low Power Mode.
    @MainActor var fps: Int {
        let screen = UIScreen.main.maximumFramesPerSecond
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        switch self {
        case .auto: return lowPower ? min(60, screen) : screen
        case .sixty: return min(60, screen)
        case .thirty: return 30
        }
    }

    var title: String {
        switch self {
        case .auto: String(localized: "As fast as the screen")
        case .sixty: String(localized: "60 frames a second")
        case .thirty: String(localized: "30 frames a second")
        }
    }

    var detail: String {
        switch self {
        case .auto: String(localized: "120 on a ProMotion screen, 60 on others and in Low Power Mode.")
        case .sixty: String(localized: "Smooth, and easier on the battery and the network.")
        case .thirty: String(localized: "The least data and battery.")
        }
    }
}

/// Retina displays at their pixels, or at their points for a quarter of the pixels.
enum ScreenResolution: String, CaseIterable, Identifiable {
    case retina, standard
    var id: String { rawValue }

    var maxScale: Int { self == .retina ? 2 : 1 }

    var title: String {
        switch self {
        case .retina: String(localized: "Retina")
        case .standard: String(localized: "Standard")
        }
    }

    var detail: String {
        switch self {
        case .retina: String(localized: "Every pixel of the computer's screen: sharp when zoomed in.")
        case .standard: String(localized: "Half the width and height: lighter, softer up close.")
        }
    }
}

/// How fingers drive the computer.
enum ScreenInputMode: String, CaseIterable, Identifiable {
    case trackpad, touch
    var id: String { rawValue }

    var title: String {
        switch self {
        case .trackpad: String(localized: "Trackpad")
        case .touch: String(localized: "Touch")
        }
    }

    var detail: String {
        switch self {
        case .trackpad: String(localized: "The whole screen is a trackpad: a finger moves the cursor, a tap clicks where it is.")
        case .touch: String(localized: "A tap clicks where you touch, a finger scrolls, touch and hold to drag. An iPad's trackpad or mouse points straight at the computer's screen, and Apple Pencil is a mouse.")
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
