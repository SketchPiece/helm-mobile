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

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
            } else if let emoji = project?.iconEmoji {
                Palette.surfaceRaised
                Text(emoji).font(.system(size: size * 0.55))
            } else {
                tileColor
                Text(project?.initials ?? "·")
                    .font(Typography.sans(size * 0.36, .semibold))
                    .foregroundStyle(.white.opacity(0.92))
            }
        }
        .frame(width: size, height: size)
        .clipShape(.rect(cornerRadius: size * 0.25, style: .continuous))
        .task(id: project?.faviconPath) { await load() }
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

    private static let namedColors: [String: Color] = [
        "gray": Color(hex: 0x6B7280), "red": Color(hex: 0xDC2626), "orange": Color(hex: 0xEA580C),
        "amber": Color(hex: 0xD97706), "yellow": Color(hex: 0xCA8A04), "lime": Color(hex: 0x65A30D),
        "green": Color(hex: 0x16A34A), "emerald": Color(hex: 0x059669), "teal": Color(hex: 0x0D9488),
        "cyan": Color(hex: 0x0891B2), "sky": Color(hex: 0x0284C7), "blue": Color(hex: 0x2563EB),
        "indigo": Color(hex: 0x4F46E5), "violet": Color(hex: 0x7C3AED), "purple": Color(hex: 0x9333EA),
        "fuchsia": Color(hex: 0xC026D3), "pink": Color(hex: 0xDB2777), "rose": Color(hex: 0xE11D48),
    ]

    private func load() async {
        guard let project, let path = project.faviconPath, let environment else {
            image = nil
            return
        }
        let key = "\(environment.id)|\(project.workspaceRoot)|\(path)"
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

actor IconCache {
    static let shared = IconCache()
    private var memory: [String: UIImage] = [:]
    private let directory: URL = {
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "project-icons")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    private func file(_ key: String) -> URL {
        let name = key.data(using: .utf8)!.base64EncodedString()
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "+", with: "-").prefix(120)
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
