import SwiftUI
import UIKit

/// A provider's official mark, ported from the React Native `ProviderIcon` (same paths,
/// viewBoxes and light/dark colours). `driver` is the provider's driver slug; `iconUrl` is
/// `ServerProvider.iconUrl`, used only for ACP Registry agents and only from the official CDN.
/// Unknown drivers get the OpenAI mark, like the original.
struct ProviderIcon: View {
    let driver: String?
    var iconUrl: String? = nil
    var size: CGFloat = 16

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let dark = colorScheme == .dark
        Group {
            if driver?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "antigravity" {
                Image("ProviderAntigravity").resizable().interpolation(.high).scaledToFit()
            } else if driver == "acpRegistry" {
                AcpRegistryIcon(iconUrl: ProviderLogo.officialAcpRegistryIconURL(iconUrl), dark: dark)
            } else {
                ProviderLogo.forDriver(driver).view(dark: dark)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// One filled vector logo: paths in viewBox coordinates, each with its light and dark fill.
struct ProviderLogo: Sendable {
    struct Layer: Sendable {
        let path: Path
        let evenOdd: Bool
        let light: UInt32
        let dark: UInt32
    }

    let viewBox: CGRect
    let layers: [Layer]

    init(viewBox: CGRect, _ layers: [(d: String, light: UInt32, dark: UInt32, evenOdd: Bool)]) {
        self.viewBox = viewBox
        // The path data is a compile-time constant; a parse failure is a typo caught by the tests.
        self.layers = layers.map { Layer(path: (try? SVGPath.path($0.d)) ?? Path(), evenOdd: $0.evenOdd, light: $0.light, dark: $0.dark) }
    }

    func view(dark: Bool) -> some View {
        ZStack {
            ForEach(layers.indices, id: \.self) { index in
                let layer = layers[index]
                ViewBoxShape(path: layer.path, viewBox: viewBox)
                    .fill(Color(hex: dark ? layer.dark : layer.light), style: FillStyle(eoFill: layer.evenOdd))
            }
        }
    }

    static func forDriver(_ driver: String?) -> ProviderLogo {
        switch driver {
        case "claudeAgent": claude
        case "grok": grok
        case "cursor": cursor
        case "pi": pi
        case "opencode": opencode
        default: openAI
        }
    }

    /// `#171717` / `#e5e5e5`: the neutral ink for marks without a brand colour.
    static let monoLight: UInt32 = 0x171717
    static let monoDark: UInt32 = 0xE5E5E5

    static let claude = ProviderLogo(viewBox: CGRect(x: 0, y: 0, width: 256, height: 257), [
        (d: "m50.228 170.321 50.357-28.257.843-2.463-.843-1.361h-2.462l-8.426-.518-28.775-.778-24.952-1.037-24.175-1.296-6.092-1.297L0 125.796l.583-3.759 5.12-3.434 7.324.648 16.202 1.101 24.304 1.685 17.629 1.037 26.118 2.722h4.148l.583-1.685-1.426-1.037-1.101-1.037-25.147-17.045-27.22-18.017-14.258-10.37-7.713-5.25-3.888-4.925-1.685-10.758 7-7.713 9.397.649 2.398.648 9.527 7.323 20.35 15.75L94.817 91.9l3.889 3.24 1.555-1.102.195-.777-1.75-2.917-14.453-26.118-15.425-26.572-6.87-11.018-1.814-6.61c-.648-2.723-1.102-4.991-1.102-7.778l7.972-10.823L71.42 0 82.05 1.426l4.472 3.888 6.61 15.101 10.694 23.786 16.591 32.34 4.861 9.592 2.592 8.879.973 2.722h1.685v-1.556l1.36-18.211 2.528-22.36 2.463-28.776.843-8.1 4.018-9.722 7.971-5.25 6.222 2.981 5.12 7.324-.713 4.73-3.046 19.768-5.962 30.98-3.889 20.739h2.268l2.593-2.593 10.499-13.934 17.628-22.036 7.778-8.749 9.073-9.657 5.833-4.601h11.018l8.1 12.055-3.628 12.443-11.342 14.388-9.398 12.184-13.48 18.147-8.426 14.518.778 1.166 2.01-.194 30.46-6.481 16.462-2.982 19.637-3.37 8.88 4.148.971 4.213-3.5 8.62-20.998 5.184-24.628 4.926-36.682 8.685-.454.324.519.648 16.526 1.555 7.065.389h17.304l32.21 2.398 8.426 5.574 5.055 6.805-.843 5.184-12.962 6.611-17.498-4.148-40.83-9.721-14-3.5h-1.944v1.167l11.666 11.406 21.387 19.314 26.767 24.887 1.36 6.157-3.434 4.86-3.63-.518-23.526-17.693-9.073-7.972-20.545-17.304h-1.36v1.814l4.73 6.935 25.017 37.59 1.296 11.536-1.814 3.76-6.481 2.268-7.13-1.297-14.647-20.544-15.1-23.138-12.185-20.739-1.49.843-7.194 77.448-3.37 3.953-7.778 2.981-6.48-4.925-3.436-7.972 3.435-15.749 4.148-20.544 3.37-16.333 3.046-20.285 1.815-6.74-.13-.454-1.49.194-15.295 20.999-23.267 31.433-18.406 19.702-4.407 1.75-7.648-3.954.713-7.064 4.277-6.286 25.47-32.405 15.36-20.092 9.917-11.6-.065-1.686h-.583L44.07 198.125l-12.055 1.555-5.185-4.86.648-7.972 2.463-2.593 20.35-13.999-.064.065Z", light: 0xD97757, dark: 0xD97757, evenOdd: false),
    ])

    static let grok = ProviderLogo(viewBox: CGRect(x: 0, y: 0, width: 24, height: 24), [
        (d: "M9.26905 15.284L17.2479 9.36086C17.6391 9.07047 18.1981 9.18374 18.3845 9.63478C19.3655 12.0135 18.9272 14.8721 16.9755 16.8349C15.0238 18.7976 12.3082 19.228 9.8261 18.2477L7.1146 19.5102C11.0037 22.1834 15.7263 21.5223 18.6774 18.5525C21.0182 16.1985 21.7432 12.9897 21.0653 10.0961L21.0714 10.1023C20.0884 5.85143 21.3131 4.15233 23.8218 0.677913C23.8812 0.595532 23.9406 0.513151 24 0.428711L20.6987 3.74866V3.73836L9.267 15.2861", light: 0x0F0F0F, dark: 0xF5F5F5, evenOdd: false),
        (d: "M7.62249 16.7237C4.83113 14.0422 5.3124 9.89222 7.69417 7.49905C9.45541 5.72786 12.341 5.00497 14.86 6.06768L17.5653 4.81138C17.0779 4.45714 16.4533 4.07613 15.7365 3.80839C12.4966 2.46764 8.6178 3.13492 5.98413 5.78141C3.45081 8.32904 2.65415 12.2463 4.02219 15.5889C5.04412 18.0871 3.36889 19.8541 1.68137 21.6377C1.08337 22.2699 0.483318 22.9022 0 23.5716L7.62045 16.7257", light: 0x0F0F0F, dark: 0xF5F5F5, evenOdd: false),
    ])

    static let cursor = ProviderLogo(viewBox: CGRect(x: 0, y: 0, width: 466.73, height: 532.09), [
        (d: "M457.43,125.94L244.42,2.96c-6.84-3.95-15.28-3.95-22.12,0L9.3,125.94c-5.75,3.32-9.3,9.46-9.3,16.11v247.99c0,6.65,3.55,12.79,9.3,16.11l213.01,122.98c6.84,3.95,15.28,3.95,22.12,0l213.01-122.98c5.75-3.32,9.3-9.46,9.3-16.11v-247.99c0-6.65-3.55-12.79-9.3-16.11h-.01ZM444.05,151.99l-205.63,356.16c-1.39,2.4-5.06,1.42-5.06-1.36v-233.21c0-4.66-2.49-8.97-6.53-11.31L24.87,145.67c-2.4-1.39-1.42-5.06,1.36-5.06h411.26c5.84,0,9.49,6.33,6.57,11.39h-.01Z", light: 0x26251E, dark: 0xEDECEC, evenOdd: false),
    ])

    static let pi = ProviderLogo(viewBox: CGRect(x: 165.29, y: 165.29, width: 469.43, height: 469.43), [
        (d: "M165.29 165.29H517.36V400H400V517.36H282.65V634.72H165.29ZM282.65 282.65V400H400V282.65Z", light: 0x0F0F0F, dark: 0xF5F5F5, evenOdd: true),
        (d: "M517.36 400H634.72V634.72H517.36Z", light: 0x0F0F0F, dark: 0xF5F5F5, evenOdd: false),
    ])

    static let opencode = ProviderLogo(viewBox: CGRect(x: 0, y: 0, width: 32, height: 40), [
        (d: "M24 32H8V16H24V32Z", light: 0xCFCECD, dark: 0x4B4646, evenOdd: false),
        (d: "M24 8H8V32H24V8ZM32 40H0V0H32V40Z", light: 0x211E1E, dark: 0xF1ECEC, evenOdd: false),
    ])

    /// Codex, and any driver without its own mark.
    static let openAI = ProviderLogo(viewBox: CGRect(x: 100, y: 100, width: 411, height: 411), [
        (d: "M252.794 108.802C289.191 99.0484 326.265 110.305 351.148 135.135C385.113 126.072 422.85 134.862 449.492 161.505C476.136 188.149 484.925 225.888 475.862 259.85V259.854C500.696 284.735 511.95 321.81 502.198 358.207C492.447 394.602 464.161 421.084 430.215 430.217C421.083 464.162 394.603 492.448 358.206 502.199C321.812 511.951 284.734 500.693 259.852 475.864C225.887 484.927 188.15 476.137 161.507 449.495C134.864 422.851 126.073 385.111 135.136 351.149C110.304 326.266 99.0496 289.192 108.801 252.795C118.552 216.4 146.84 189.918 180.784 180.785C189.917 146.841 216.396 118.553 252.794 108.802ZM374.292 407.145C374.292 411.271 372.092 415.086 368.517 417.148L283.723 466.102C302.487 480.585 327.555 486.459 352.217 479.852C386.997 470.532 410.068 439.312 410.555 405.006V317.717C410.555 315.08 409.125 312.621 406.843 311.303L374.292 292.509V407.145ZM251.868 415.897C248.296 417.959 243.893 417.959 240.317 415.897L155.526 366.942C152.366 390.436 159.811 415.08 177.866 433.136H177.863C203.325 458.594 241.896 462.962 271.85 446.232L347.449 402.586C349.735 401.268 351.148 398.8 351.148 396.163V358.579L251.868 415.897ZM368.602 220.628C366.319 219.309 363.474 219.318 361.191 220.637L328.641 239.431L427.921 296.749C431.496 298.811 433.697 302.627 433.697 306.752V404.661C455.622 395.654 473.244 376.881 479.851 352.218C489.169 317.442 473.668 281.85 444.201 264.274L368.602 220.628ZM177.303 206.34C155.377 215.348 137.756 234.122 131.148 258.783C121.832 293.561 137.331 329.153 166.799 346.727L242.398 390.373C244.68 391.692 247.525 391.684 249.807 390.366L282.357 371.572L183.078 314.253C179.504 312.189 177.303 308.375 177.303 304.251V206.34ZM259.849 279.145V331.858L305.5 358.213L351.15 331.858V279.145L305.5 252.789L259.849 279.145ZM327.276 144.9C308.512 130.418 283.445 124.543 258.782 131.15C224.002 140.471 200.931 171.691 200.445 205.995V293.286C200.445 295.923 201.875 298.381 204.158 299.7L236.707 318.493V203.856C236.707 199.731 238.909 195.916 242.483 193.853L327.276 144.9ZM433.137 177.867C407.675 152.407 369.103 148.038 339.149 164.769L263.55 208.415C261.265 209.734 259.852 212.202 259.852 214.838V252.423L359.132 195.105C362.703 193.041 367.108 193.041 370.682 195.105L455.473 244.06C458.635 220.567 451.189 195.922 433.135 177.867H433.137Z", light: monoLight, dark: monoDark, evenOdd: true),
    ])

    /// Shown for ACP Registry agents until (or instead of) their remote icon.
    static let acpRegistry = ProviderLogo(viewBox: CGRect(x: 0, y: 0, width: 576, height: 220), [
        (d: "M568.003 115.821 517.278 27.966C507.183 10.482 489.084.023 468.894.023c-20.167 0-38.22 10.413-48.338 27.852L343.251 161.75H242.755c-6.525 0-12.369-3.365-15.62-9.004-3.274-5.639-3.274-12.369 0-18.03l50.726-87.855c3.251-5.639 9.094-9.027 15.62-9.027 6.525 0 12.346 3.365 15.62 9.027l3.024 5.229a6.81 6.81 0 0 0 5.911 3.411c2.433 0 4.707-1.319 5.912-3.433l13.437-23.555c1.41-2.479 1.137-5.571-.682-7.753C325.699 7.57 309.874 0 293.322 0c-.66 0-1.319 0-2.001.045-19.281.705-36.561 11.141-46.247 27.898l-44.859 77.714-44.405-76.509C145.465 11.209 126.594.023 106.608.023c-.659 0-1.319 0-2.001.045-19.28.705-36.56 11.141-46.246 27.898L7.658 115.821c-13.915 24.078-8.526 52.999 13.392 71.938 8.844 7.663 20.554 11.869 32.968 11.869h94.63c2.433 0 4.684-1.296 5.912-3.411l13.96-24.191a6.81 6.81 0 0 0 0-6.821c-1.228-2.115-3.479-3.411-5.912-3.411H56.042c-6.526 0-12.369-3.365-15.62-9.004-3.275-5.638-3.275-12.368 0-18.03l50.725-87.854c3.252-5.639 9.095-9.027 15.62-9.027 6.526 0 12.346 3.365 15.62 9.027l72.439 125.62c.205.364.432.682.705 1 3.229 5.139 7.299 9.959 12.255 14.256 8.845 7.662 20.554 11.869 32.968 11.869h80.67l-5.843 10.118a6.81 6.81 0 0 0 0 6.821c1.228 2.114 3.478 3.41 5.911 3.41h27.944c2.432 0 4.683-1.296 5.911-3.41l9.049-15.689 2.774-4.433.114-.205 85.99-149.334c3.251-5.639 9.095-9.027 15.62-9.027 6.526 0 12.369 3.365 15.62 9.027l50.726 87.855c3.251 5.639 3.274 12.391 0 18.03-3.252 5.639-9.095 9.027-15.62 9.027H418.669c-2.433 0-4.684 1.296-5.912 3.41l-13.983 24.192a6.81 6.81 0 0 0 0 6.821c1.228 2.114 3.479 3.41 5.912 3.41H518.21c21.6 0 41.085-11.436 50.816-29.83 9.027-17.053 8.64-37.22-1.045-54Z", light: monoLight, dark: monoDark, evenOdd: false),
    ])

    /// Port of contracts' `resolveOfficialAcpRegistryIconUrl`: only https URLs on the
    /// credential-free official Registry CDN, no port or user info.
    static func officialAcpRegistryIconURL(_ icon: String?) -> URL? {
        guard let icon, !icon.isEmpty, let components = URLComponents(string: icon),
              components.scheme == "https", components.host == "cdn.agentclientprotocol.com",
              components.port == nil, components.user == nil, components.password == nil
        else { return nil }
        return components.url
    }
}

/// Draws a path given in viewBox coordinates, aspect-fit and centred in the frame (SVG's
/// default `xMidYMid meet`).
private struct ViewBoxShape: Shape {
    let path: Path
    let viewBox: CGRect

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width / viewBox.width, rect.height / viewBox.height)
        let x = rect.midX - viewBox.midX * scale
        let y = rect.midY - viewBox.midY * scale
        return path.applying(CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: x, ty: y))
    }
}

/// An ACP Registry agent's own icon from the official CDN, tinted with the neutral ink like
/// RN's `tintColor`; the Registry mark shows until it loads or when it can't.
private struct AcpRegistryIcon: View {
    let iconUrl: URL?
    let dark: Bool

    @State private var loaded: (url: URL, image: UIImage)?

    var body: some View {
        Group {
            if let loaded, loaded.url == iconUrl {
                Image(uiImage: loaded.image)
                    .renderingMode(.template)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .foregroundStyle(Color(hex: dark ? ProviderLogo.monoDark : ProviderLogo.monoLight))
            } else {
                ProviderLogo.acpRegistry.view(dark: dark)
            }
        }
        .task(id: iconUrl) {
            guard let iconUrl else { return }
            if let image = await Self.load(iconUrl) { loaded = (iconUrl, image) }
        }
    }

    /// Registry icons are SVG, so they go through the WebKit rasteriser once and are cached
    /// alongside project icons.
    private static func load(_ url: URL) async -> UIImage? {
        let key = "acp-registry|\(url.absoluteString)"
        if let cached = await IconCache.shared.image(for: key) { return cached }
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        let image: UIImage?
        if let bitmap = UIImage(data: data) {
            image = bitmap
        } else {
            image = await SVGRasterizer.shared.render(data, size: 64)
        }
        if let image { await IconCache.shared.store(image, for: key) }
        return image
    }
}
