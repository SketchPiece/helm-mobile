import SwiftUI
import XCTest
@testable import HelmMobile

/// Renders the Usage widget's face at both sizes, light and dark, so it can be looked at without
/// adding it to a home screen. PNGs land in $HELM_UI_SHOTS (default /tmp/hm-ui-settings).
@MainActor
final class UsageWidgetRenderTests: XCTestCase {
    func testRendersEveryFamilyAndAppearance() throws {
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["HELM_UI_SHOTS"] ?? "/tmp/hm-ui-settings")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, small, size) in [("small", true, CGSize(width: 170, height: 170)), ("medium", false, CGSize(width: 364, height: 170))] {
            for scheme in [ColorScheme.light, .dark] {
                for (label, snapshot) in [("data", UsageSnapshot.preview), ("empty", nil)] {
                    let view = UsageWidgetView(snapshot: snapshot, small: small)
                        .padding(16)
                        .frame(width: size.width, height: size.height)
                        .background(UsageWidgetColors.background)
                        .clipShape(.rect(cornerRadius: 22))
                        .environment(\.colorScheme, scheme)
                    let renderer = ImageRenderer(content: view)
                    renderer.scale = 3
                    let image = try XCTUnwrap(renderer.uiImage, "\(name) \(scheme)")
                    XCTAssertEqual(image.size, size)
                    let data = try XCTUnwrap(image.pngData())
                    try? data.write(to: directory.appendingPathComponent("widget-\(name)-\(label)-\(scheme == .dark ? "dark" : "light").png"))
                }
            }
        }
    }
}
