import SwiftUI
import WebKit

/// A page the agent published with `html_render`, in the reply where the desktop shows it. The
/// frame starts at the height the Mac measured and then fits the page as drawn here; the corner
/// button opens it full screen, where it scrolls and zooms.
struct HtmlRenderCard: View {
    let render: HtmlRender
    let environment: EnvironmentSession

    @Environment(\.colorScheme) private var colorScheme
    @State private var html: String?
    @State private var failed = false
    @State private var width: Double = 0
    @State private var contentHeight: Double?
    @State private var fullScreen = false

    var body: some View {
        let theme = HtmlRenderTheme(ThemeStore.shared.theme, dark: colorScheme == .dark)
        ZStack(alignment: .topTrailing) {
            if let html {
                HtmlPageWebView(html: html, title: render.title, theme: theme, nested: true) { contentHeight = $0 }
                Button {
                    fullScreen = true
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Palette.textMuted)
                        .frame(width: 28, height: 28)
                        .background(Palette.surface.opacity(0.85), in: .circle)
                        .overlay(Circle().strokeBorder(Palette.border))
                        .padding(8)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .padding(-2)
                .accessibilityLabel(Text("Open \(render.title)"))
            } else if failed {
                Button {
                    failed = false
                    Task { await load() }
                } label: {
                    Label("Page unavailable", systemImage: "arrow.clockwise")
                        .font(Typography.footnote)
                        .foregroundStyle(Palette.textMuted)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: render.frameHeight(width: width > 0 ? width : 375, contentHeight: contentHeight))
        .onGeometryChange(for: Double.self) { $0.size.width } action: { width = $0 }
        .task(id: render.attachmentId) { await load() }
        .sheet(isPresented: $fullScreen) {
            if let html {
                HtmlRenderSheet(html: html, render: render)
            }
        }
        .accessibilityIdentifier("htmlRender")
    }

    private func load() async {
        guard html == nil else { return }
        if let page = await HtmlPageLoader.page(render, environment: environment) {
            html = page
        } else {
            failed = true
        }
    }
}

private struct HtmlRenderSheet: View {
    let html: String
    let render: HtmlRender

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let theme = HtmlRenderTheme(ThemeStore.shared.theme, dark: colorScheme == .dark)
        NavigationStack {
            HtmlPageWebView(html: html, title: render.title, theme: theme, nested: false)
                .padding(.horizontal, 16)
                .background(Palette.canvas)
                .navigationTitle(render.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(role: .close) { dismiss() }
                    }
                }
        }
    }
}

/// The published page, fetched once per session. The Mac stores it with the theme bootstrap
/// already in its head and local images inlined, so it loads on its own.
enum HtmlPageLoader {
    @MainActor private static let cache: NSCache<NSString, NSString> = {
        let cache = NSCache<NSString, NSString>()
        cache.totalCostLimit = 16 * 1024 * 1024
        return cache
    }()

    @MainActor
    static func page(_ render: HtmlRender, environment: EnvironmentSession) async -> String? {
        let key = render.attachmentId as NSString
        if let cached = cache.object(forKey: key) { return cached as String }
        guard let result = try? await environment.call("assets.createUrl", [
            "resource": ["_tag": "attachment", "attachmentId": .string(render.attachmentId),
                         "fileName": .string(render.fileName), "mimeType": "text/html", "disposition": "inline"],
        ]), let relative = result["relativeUrl"]?.string,
            let (data, response) = try? await HelmHTTP.session.data(from: environment.http.url(relative)),
            (response as? HTTPURLResponse)?.statusCode ?? 200 < 400,
            let html = String(data: data, encoding: .utf8)
        else { return nil }
        cache.setObject(html as NSString, forKey: key, cost: data.count)
        return html
    }
}

/// The app's colours as the CSS variables pages are written against (`htmlRenderTheme` in T3 Code).
struct HtmlRenderTheme: Equatable {
    var appearance: String
    var variables: [String: String]

    init(_ theme: HelmTheme, dark: Bool) {
        func css(_ role: PaletteRole, alpha: Double? = nil) -> String {
            let color = theme.color(role, dark: dark)
            let channel = { (value: Double) in Int((min(1, max(0, value)) * 255).rounded()) }
            return "rgba(\(channel(color.r)), \(channel(color.g)), \(channel(color.b)), \(alpha ?? color.a))"
        }
        appearance = dark ? "dark" : "light"
        variables = [
            "--background": css(.canvas), "--foreground": css(.text),
            "--muted": css(.surfaceRaised), "--muted-foreground": css(.textMuted),
            "--card": css(.surface), "--card-foreground": css(.text),
            "--popover": css(.surfaceRaised), "--popover-foreground": css(.text),
            "--secondary": css(.surfaceRaised), "--secondary-foreground": css(.text),
            "--border": css(.border), "--input": css(.input), "--ring": css(.accentText),
            "--primary": css(.accent), "--primary-foreground": css(.accentForeground),
            "--accent": css(.accent), "--accent-foreground": css(.accentForeground),
            "--accent-surface": css(.accent, alpha: 0.14), "--accent-surface-foreground": css(.accentText),
            "--destructive": css(.error), "--destructive-foreground": css(.errorText),
            "--destructive-surface": css(.errorSurface),
            "--warning": "#f59e0b", "--warning-foreground": dark ? "#fbbf24" : "#b45309",
            "--warning-surface": css(.warningSurface),
            "--success": "#10b981", "--success-foreground": dark ? "#34d399" : "#047857",
            "--info": "#3b82f6", "--info-foreground": dark ? "#60a5fa" : "#1d4ed8",
            "--code-background": css(.code), "--code-foreground": css(.codeText),
            "--chart-1": css(.accent),
            "--radius": "0.625rem",
            "--font-sans": #"-apple-system, BlinkMacSystemFont, "Segoe UI", system-ui, sans-serif"#,
            "--font-mono": #""SF Mono", "SFMono-Regular", Menlo, Consolas, "Liberation Mono", monospace"#,
        ]
        let chart = dark ? ["#2dd4bf", "#fbbf24", "#c084fc", "#fb7185", "#a3e635"]
                         : ["#0d9488", "#d97706", "#9333ea", "#e11d48", "#65a30d"]
        for (index, color) in chart.enumerated() { variables["--chart-\(index + 2)"] = color }
    }

    var json: String {
        let object: [String: Any] = ["appearance": appearance, "variables": variables]
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}

/// The page in a web view. Nested in the thread it doesn't scroll, so the thread does, and reports
/// its content height; full screen it scrolls and zooms. Links leave for the browser or the app.
struct HtmlPageWebView: UIViewRepresentable {
    let html: String
    let title: String
    let theme: HtmlRenderTheme
    let nested: Bool
    var onContentHeight: ((Double) -> Void)?

    @Environment(\.openURL) private var openURL

    /// The page's own origin, so the bootstrap can rewrite its URL; nothing is fetched from it.
    fileprivate static let baseURL = URL(string: "https://helm-page.invalid/page")!
    private static let heightMessage = "helmPageHeight"

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.websiteDataStore = .nonPersistent()
        let controller = configuration.userContentController
        // The bootstrap reads the theme from the URL's fragment before the page's own styles.
        controller.addUserScript(WKUserScript(
            source: "history.replaceState(null, \"\", \"#t3-theme=\" + encodeURIComponent(\(Self.jsString(theme.json))));",
            injectionTime: .atDocumentStart, forMainFrameOnly: true))
        if nested {
            // Measured as the desktop measures a framed page.
            controller.addUserScript(WKUserScript(source: """
                (function(){var h;function z(){var r=document.documentElement,v=Math.ceil(r.scrollHeight>r.clientHeight?r.scrollHeight:r.getBoundingClientRect().height);if(v===h)return;h=v;window.webkit.messageHandlers.\(Self.heightMessage).postMessage(v);}if(window.ResizeObserver){var o=new ResizeObserver(z);o.observe(document.documentElement);if(document.body)o.observe(document.body);}window.addEventListener("load",z);z();})();
                """, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
            controller.add(context.coordinator, name: Self.heightMessage)
        }
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.contentInsetAdjustmentBehavior = nested ? .never : .automatic
        webView.scrollView.isScrollEnabled = !nested
        webView.scrollView.bounces = !nested
        webView.scrollView.showsVerticalScrollIndicator = !nested
        webView.accessibilityLabel = title
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        context.coordinator.parent = self
        context.coordinator.shownTheme = theme
        webView.loadHTMLString(html, baseURL: Self.baseURL)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        guard context.coordinator.shownTheme != theme else { return }
        context.coordinator.shownTheme = theme
        let message = """
            {"jsonrpc":"2.0","method":"ui/notifications/host-context-changed","params":{"theme":"\(theme.appearance)","styles":\(theme.json)}}
            """
        webView.evaluateJavaScript("window.postMessage(\(message), \"*\"); true;")
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: heightMessage)
    }

    private static func jsString(_ value: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [value])) ?? Data("[\"\"]".utf8)
        return String(decoding: data, as: UTF8.self) + "[0]"
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        var parent: HtmlPageWebView?
        var shownTheme: HtmlRenderTheme?

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let height = message.body as? Double, height.isFinite, height > 0 else { return }
            parent?.onContentHeight?(height)
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard let url = action.request.url else { return .cancel }
            if action.targetFrame?.isMainFrame == false { return .allow }
            if url.host == HtmlPageWebView.baseURL.host { return .allow }
            if action.navigationType == .linkActivated { open(url) }
            return .cancel
        }

        /// A link the bootstrap sent to a new window (`target=_blank`).
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = action.request.url { open(url) }
            return nil
        }

        /// The web content process died (memory pressure): draw the page again.
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            guard let parent else { return }
            webView.loadHTMLString(parent.html, baseURL: HtmlPageWebView.baseURL)
        }

        private func open(_ url: URL) {
            Task { @MainActor in parent?.openURL(url) }
        }
    }
}
