import CryptoKit
import SwiftUI
import WebKit

/// A project's tile: its favicon from the server when it has one, otherwise a coloured
/// monogram. Favicons are often SVG, which UIKit can't decode, so they are rasterised once
/// with WebKit and cached in memory and on disk.
struct ProjectIcon: View {
    let project: Project?
    let environment: EnvironmentSession?
    var size: CGFloat = 36

    @State private var image: UIImage?

    /// The project's favicon as a menu image, from the cache, drawn by hand: favicons rasterised
    /// by WebKit don't survive SwiftUI's ImageRenderer. Nil when there is none to show.
    static func menuFavicon(project: Project, environment: EnvironmentSession, size: CGFloat = 24) async -> UIImage? {
        guard !environment.isScratch(project),
              let key = cacheKey(project: project, environment: environment),
              let favicon = await IconCache.shared.image(for: key)
        else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        let rect = CGRect(x: 0, y: 0, width: size, height: size)
        return UIGraphicsImageRenderer(size: rect.size, format: format).image { _ in
            UIBezierPath(roundedRect: rect, cornerRadius: size * 0.25).addClip()
            // Fill the square, as the tile's scaledToFill does.
            let scale = max(size / max(favicon.size.width, 1), size / max(favicon.size.height, 1))
            let drawn = CGSize(width: favicon.size.width * scale, height: favicon.size.height * scale)
            favicon.draw(in: CGRect(x: (size - drawn.width) / 2, y: (size - drawn.height) / 2,
                                    width: drawn.width, height: drawn.height))
        }.withRenderingMode(.alwaysOriginal)
    }

    /// The tile without a favicon (monogram, emoji, or the scratch bubble) as a menu image, drawn
    /// right away so a menu never waits on it. Kept per look, since menus redraw with the list.
    static func menuTile(project: Project, environment: EnvironmentSession, size: CGFloat = 24) -> UIImage? {
        let key = "\(project.id)|\(project.title)|\(project.iconKind ?? "")|\(project.iconEmoji ?? "")|\(project.iconColor ?? "")|\(environment.isScratch(project))"
        if let cached = menuTiles[key] { return cached }
        let renderer = ImageRenderer(content: ProjectIcon(project: project, environment: environment, size: size))
        renderer.scale = 3
        let image = renderer.uiImage?.withRenderingMode(.alwaysOriginal)
        menuTiles[key] = image
        return image
    }

    private static var menuTiles: [String: UIImage] = [:]

    private static func cacheKey(project: Project, environment: EnvironmentSession) -> String? {
        guard let path = project.faviconPath, project.iconKind == nil else { return nil }
        return "\(environment.id)|\(project.workspaceRoot)|\(path)"
    }

    var body: some View {
        if let project, environment?.isScratch(project) == true {
            ScratchIcon(size: size)
        } else {
            tile
        }
    }

    private var tile: some View {
        ZStack {
            if project?.iconKind == "emoji", let emoji = project?.iconEmoji {
                Palette.surfaceRaised
                Text(emoji).font(.system(size: size * 0.55))
            } else if project?.iconKind != "monogram", let image {
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
            } else {
                tileColor
                Text(project?.initials ?? "·")
                    .font(Typography.sans(size * 0.36, .semibold))
                    .foregroundStyle(.white.opacity(0.92))
            }
        }
        .frame(width: size, height: size)
        .clipShape(.rect(cornerRadius: size * 0.25, style: .continuous))
        .task(id: project.map { "\($0.faviconPath ?? "")|\($0.iconKind ?? "")" }) { await load() }
    }

    private var tileColor: Color {
        if let name = project?.iconColor, let color = Self.namedColors[name] { return color }
        let palette: [Color] = [
            Color(hex: 0x6E5BB0), Color(hex: 0x2E8C80), Color(hex: 0xB8321F), Color(hex: 0x9C7A45),
            Color(hex: 0x3E7A2E), Color(hex: 0x3D6FB0), Color(hex: 0x8E4E8C), Color(hex: 0x5E554B),
        ]
        let hash = (project?.id ?? "").unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return palette[hash % palette.count]
    }

    /// The server's icon colours, in the order the colour picker shows them.
    static let colorNames = ["red", "orange", "amber", "yellow", "lime", "green", "emerald", "teal", "cyan",
                             "sky", "blue", "indigo", "violet", "purple", "fuchsia", "pink", "rose", "gray"]

    static let namedColors: [String: Color] = [
        "gray": Color(hex: 0x6B7280), "red": Color(hex: 0xDC2626), "orange": Color(hex: 0xEA580C),
        "amber": Color(hex: 0xD97706), "yellow": Color(hex: 0xCA8A04), "lime": Color(hex: 0x65A30D),
        "green": Color(hex: 0x16A34A), "emerald": Color(hex: 0x059669), "teal": Color(hex: 0x0D9488),
        "cyan": Color(hex: 0x0891B2), "sky": Color(hex: 0x0284C7), "blue": Color(hex: 0x2563EB),
        "indigo": Color(hex: 0x4F46E5), "violet": Color(hex: 0x7C3AED), "purple": Color(hex: 0x9333EA),
        "fuchsia": Color(hex: 0xC026D3), "pink": Color(hex: 0xDB2777), "rose": Color(hex: 0xE11D48),
    ]

    private func load() async {
        guard let project, let environment, let path = project.faviconPath,
              let key = Self.cacheKey(project: project, environment: environment)
        else {
            image = nil
            return
        }
        if let cached = await IconCache.shared.image(for: key) {
            image = cached
            return
        }
        guard environment.isLive,
              let result = try? await environment.call("assets.createUrl", [
                  "resource": ["_tag": "project-favicon", "cwd": .string(project.workspaceRoot), "path": .string(path)],
              ]),
              let relative = result["relativeUrl"]?.string
        else { return }
        let url = environment.http.url(relative)
        guard let (data, _) = try? await HelmHTTP.session.data(from: url) else { return }
        let rendered: UIImage?
        if let bitmap = UIImage(data: data) {
            rendered = bitmap
        } else {
            rendered = await SVGRasterizer.shared.render(data, size: 96)
        }
        if let rendered {
            await IconCache.shared.store(rendered, for: key)
            image = rendered
        }
    }
}

/// The tile for "No project" threads: a chat bubble with text lines, the same everywhere.
struct ScratchIcon: View {
    var size: CGFloat = 36

    var body: some View {
        Image(systemName: "text.bubble")
            .font(.system(size: size * 0.4))
            .foregroundStyle(Palette.textMuted)
            .frame(width: size, height: size)
            .background(Palette.surfaceRaised, in: .rect(cornerRadius: size * 0.25, style: .continuous))
    }
}

actor IconCache {
    static let shared = IconCache()
    private var memory: [String: UIImage] = [:]
    private let directory: URL = {
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "project-icons")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// The whole key is hashed: a truncated key dropped the favicon path for deep workspaces,
    /// so a project's new icon kept loading the old file from disk.
    private func file(_ key: String) -> URL {
        let name = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appending(path: "\(name).png")
    }

    func image(for key: String) -> UIImage? {
        if let image = memory[key] { return image }
        guard let data = try? Data(contentsOf: file(key)), let image = UIImage(data: data) else { return nil }
        memory[key] = image
        return image
    }

    func store(_ image: UIImage, for key: String) {
        memory[key] = image
        try? image.pngData()?.write(to: file(key))
    }
}

/// Rasterises SVG data with an offscreen WKWebView, one at a time.
@MainActor
final class SVGRasterizer: NSObject, WKNavigationDelegate {
    static let shared = SVGRasterizer()
    private var webView: WKWebView?
    private var queue: [(Data, CGFloat, CheckedContinuation<UIImage?, Never>)] = []
    private var current: (Int, CheckedContinuation<UIImage?, Never>)?
    private var generation = 0

    func render(_ data: Data, size: CGFloat) async -> UIImage? {
        await withCheckedContinuation { continuation in
            queue.append((data, size, continuation))
            pump()
        }
    }

    private func pump() {
        guard current == nil, !queue.isEmpty else { return }
        let (data, size, continuation) = queue.removeFirst()
        generation += 1
        let token = generation
        current = (token, continuation)
        let webView = webView ?? {
            let view = WKWebView(frame: CGRect(x: 0, y: 0, width: size, height: size))
            view.isOpaque = false
            view.backgroundColor = .clear
            view.scrollView.isScrollEnabled = false
            view.navigationDelegate = self
            self.webView = view
            return view
        }()
        webView.frame = CGRect(x: 0, y: 0, width: size, height: size)
        let svg = data.base64EncodedString()
        let html = """
        <html><head><meta name="viewport" content="width=\(Int(size)),initial-scale=1">
        <style>html,body{margin:0;padding:0;background:transparent}img{width:\(Int(size))px;height:\(Int(size))px;display:block}</style>
        </head><body><img src="data:image/svg+xml;base64,\(svg)"></body></html>
        """
        webView.loadHTMLString(html, baseURL: nil)
        Task {
            try? await Task.sleep(for: .seconds(5))
            if self.current?.0 == token { self.finish(nil) }
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            // Give the <img> a frame to decode before snapshotting.
            try? await Task.sleep(for: .milliseconds(60))
            let config = WKSnapshotConfiguration()
            config.afterScreenUpdates = true
            let image = try? await webView.takeSnapshot(configuration: config)
            self.finish(image)
        }
    }

    private func finish(_ image: UIImage?) {
        guard let (_, continuation) = current else { return }
        current = nil
        continuation.resume(returning: image)
        pump()
    }
}
