import SwiftUI

/// Settings → Computer screen: how the computer's screen opens here, which display, how sharp,
/// how it's driven, and its sound and clipboard.
struct ScreenRemoteSettingsView: View {
    @AppStorage(PhonePreferences.screenOpenZoomKey) private var openZoom = ScreenOpenZoom.fill
    @AppStorage(PhonePreferences.screenDisplayKey) private var display = ScreenDisplayChoice.main
    @AppStorage(PhonePreferences.screenVirtualSizeKey) private var virtualSize = ScreenVirtualSize.same
    @AppStorage(PhonePreferences.screenKeepDisplayKey) private var keepDisplay = ScreenKeepDisplay.short
    @AppStorage(PhonePreferences.screenQualityKey) private var quality = ScreenQuality.standard
    @AppStorage(PhonePreferences.screenFrameRateKey) private var frameRate = ScreenFrameRate.auto
    @AppStorage(PhonePreferences.screenResolutionKey) private var resolution = ScreenResolution.retina
    @AppStorage(PhonePreferences.screenInputModeKey) private var inputMode = ScreenInputMode.trackpad
    @AppStorage(PhonePreferences.screenCursorSpeedKey) private var cursorSpeed = ScreenCursorSpeed.normal
    @AppStorage(PhonePreferences.screenReverseScrollKey) private var reverseScroll = false
    @AppStorage(PhonePreferences.screenClickFeedbackKey) private var clickFeedback = true
    @AppStorage(PhonePreferences.screenSoundKey) private var sound = false
    @AppStorage(PhonePreferences.screenClipboardKey) private var clipboard = true
    @AppStorage(PhonePreferences.screenAwayKey) private var away = true
    @AppStorage(PhonePreferences.screenAwayQualityKey) private var awayQuality = ScreenQuality.awayStandard
    @AppStorage(PhonePreferences.screenAwayFrameRateKey) private var awayFrameRate = ScreenFrameRate.awayStandard
    @AppStorage(PhonePreferences.screenAwayResolutionKey) private var awayResolution = ScreenResolution.awayStandard

    /// The separate display is the iPad's: only there are its settings shown.
    private var hasSeparateDisplay: Bool { ScreenDisplayChoice.available.contains(.virtual) }

    var body: some View {
        HelmForm {
            Section {
                ChoiceRows(options: ScreenDisplayChoice.available, selection: $display, label: \.title, detail: \.detail)
            } header: {
                Text("Opens on").sectionLabelStyle()
            } footer: {
                Text("While it's open, the toolbar's display button switches between them.")
                    .font(Typography.footnote)
            }
            if hasSeparateDisplay {
                Section {
                    ChoiceRows(options: ScreenVirtualSize.allCases, selection: $virtualSize, label: \.title, detail: \.detail)
                } header: {
                    Text("Separate display size").sectionLabelStyle()
                } footer: {
                    Text("It turns with the iPad and follows its window in Split View and Stage Manager.")
                        .font(Typography.footnote)
                }
                Section {
                    ChoiceRows(options: ScreenKeepDisplay.allCases, selection: $keepDisplay, label: \.title, detail: \.detail)
                } header: {
                    Text("Remove the separate display").sectionLabelStyle()
                }
            }
            Section {
                ChoiceRows(options: ScreenOpenZoom.allCases, selection: $openZoom, label: \.title, detail: \.detail)
            } header: {
                Text("Zoom").sectionLabelStyle()
            } footer: {
                Text("Pinch or use the toolbar's zoom button to change it while it's open.")
                    .font(Typography.footnote)
            }
            Section {
                ChoiceRows(options: ScreenInputMode.allCases, selection: $inputMode, label: \.title, detail: \.detail)
            } header: {
                Text("Fingers").sectionLabelStyle()
            } footer: {
                Text("The hand button on the toolbar switches while it's open. Three fingers swipe up for Mission Control, down for App Exposé, sideways between Spaces.")
                    .font(Typography.footnote)
            }
            Section {
                Picker("Cursor speed", selection: $cursorSpeed) {
                    ForEach(ScreenCursorSpeed.allCases) { speed in
                        Text(speed.title).tag(speed)
                    }
                }
                Toggle("Reverse scrolling", isOn: $reverseScroll)
                Toggle("Ring and tap on click", isOn: $clickFeedback)
            } header: {
                Text("Control").sectionLabelStyle()
            } footer: {
                Text("Scrolling moves the content with your fingers, like on this device; reversed, it moves like a mouse wheel. The cursor speed also applies to a trackpad or mouse.")
                    .font(Typography.footnote)
            }
            .tint(Palette.accent)
            Section {
                Toggle("The computer's sound", isOn: $sound)
                Toggle("Share the clipboard", isOn: $clipboard)
            } header: {
                Text("Sound and clipboard").sectionLabelStyle()
            } footer: {
                Text("Text copied on the computer is ready to paste here. To paste this device's text on the computer, use \"Paste from this device\" in the toolbar's menu.")
                    .font(Typography.footnote)
            }
            .tint(Palette.accent)
            Section {
                ChoiceRows(options: ScreenFrameRate.allCases, selection: $frameRate, label: \.title, detail: \.detail)
            } header: {
                Text("Frame rate").sectionLabelStyle()
            }
            Section {
                ChoiceRows(options: ScreenResolution.allCases, selection: $resolution, label: \.title, detail: \.detail)
            } header: {
                Text("Resolution").sectionLabelStyle()
            }
            Section {
                ChoiceRows(options: ScreenQuality.allCases, selection: $quality, label: \.title, detail: \.detail)
            } header: {
                Text("Quality").sectionLabelStyle()
            } footer: {
                Text("Settings apply the next time the screen opens.")
                    .font(Typography.footnote)
            }
            Section {
                Toggle("Separate settings away from home", isOn: $away)
                if away {
                    Picker("Quality", selection: $awayQuality) {
                        ForEach(ScreenQuality.allCases) { Text($0.title).tag($0) }
                    }
                    Picker("Frame rate", selection: $awayFrameRate) {
                        ForEach(ScreenFrameRate.allCases) { Text($0.title).tag($0) }
                    }
                    Picker("Resolution", selection: $awayResolution) {
                        ForEach(ScreenResolution.allCases) { Text($0.title).tag($0) }
                    }
                }
            } header: {
                Text("Away from home").sectionLabelStyle()
            } footer: {
                Text("Used when the computer isn't on the network this device is on, so the picture comes through Tailscale from elsewhere, or when the device is on cellular. At home the settings above come back by themselves.")
                    .font(Typography.footnote)
            }
            .tint(Palette.accent)
        }
        .font(Typography.body)
        .scrollContentBackground(.hidden)
        .background(Palette.canvas)
        .navigationTitle("Computer screen")
        .navigationBarTitleDisplayMode(.inline)
    }
}
