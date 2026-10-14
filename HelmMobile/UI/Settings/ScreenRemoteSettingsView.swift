import SwiftUI

/// Settings → Computer screen: how the computer's screen opens here, which display, and how sharp.
struct ScreenRemoteSettingsView: View {
    @AppStorage(PhonePreferences.screenOpenZoomKey) private var openZoom = ScreenOpenZoom.fill
    @AppStorage(PhonePreferences.screenDisplayKey) private var display = ScreenDisplayChoice.main
    @AppStorage(PhonePreferences.screenVirtualSizeKey) private var virtualSize = ScreenVirtualSize.same
    @AppStorage(PhonePreferences.screenQualityKey) private var quality = ScreenQuality.sharp

    var body: some View {
        Form {
            Section {
                ChoiceRows(options: ScreenDisplayChoice.available, selection: $display, label: \.title, detail: \.detail)
            } header: {
                Text("Opens on").sectionLabelStyle()
            } footer: {
                Text("While it's open, the toolbar's display button switches between them.")
                    .font(Typography.footnote)
            }
            if display == .virtual, ScreenDisplayChoice.available.contains(.virtual) {
                Section {
                    ChoiceRows(options: ScreenVirtualSize.allCases, selection: $virtualSize, label: \.title, detail: \.detail)
                } header: {
                    Text("Separate display size").sectionLabelStyle()
                } footer: {
                    Text("It turns with the iPad and follows its window in Split View and Stage Manager.")
                        .font(Typography.footnote)
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
                ChoiceRows(options: ScreenQuality.allCases, selection: $quality, label: \.title, detail: \.detail)
            } header: {
                Text("Quality").sectionLabelStyle()
            } footer: {
                Text("Applies the next time the screen opens.")
                    .font(Typography.footnote)
            }
        }
        .font(Typography.body)
        .scrollContentBackground(.hidden)
        .background(Palette.canvas)
        .navigationTitle("Computer screen")
        .navigationBarTitleDisplayMode(.inline)
    }
}
