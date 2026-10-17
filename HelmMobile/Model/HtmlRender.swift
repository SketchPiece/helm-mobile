import Foundation

/// A page an agent published with Helm's `html_render` tool: an HTML attachment on the Mac that the
/// clients draw in the reply, above the agent's text. The tool call carries only the reference
/// (`packages/shared/src/htmlRender.ts` in T3 Code); the page itself is fetched as an attachment.
struct HtmlRender: Hashable, Sendable {
    static let minHeight: Double = 80
    static let maxHeight: Double = 2000
    /// The desktop reply column the Mac measured the page at.
    static let columnWidth: Double = 728

    var attachmentId: String
    var title: String
    var height: Double
    /// Page heights the Mac measured at several widths, sorted by width.
    var heights: [Measure]

    struct Measure: Hashable, Sendable {
        var width: Double
        var height: Double
    }

    init?(reference json: JSON) {
        guard let id = json["attachmentId"]?.string, !id.isEmpty, id.count <= 256,
              let height = json["height"]?.double, height.isFinite else { return nil }
        attachmentId = id
        let title = (json["title"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        self.title = title.isEmpty ? "HTML" : String(title.prefix(200))
        self.height = Self.clamp(height)
        heights = (json["heights"]?.array ?? []).compactMap { entry in
            guard let width = entry[0]?.double, let height = entry[1]?.double, width >= 1, height.isFinite else { return nil }
            return Measure(width: width, height: Self.clamp(height))
        }.sorted { $0.width < $1.width }
    }

    /// The page an `html_render` call published, or nil for any other item or a failed call.
    init?(item: TurnItem) {
        guard item.type == "dynamic_tool", item.status != "failed",
              Self.isRenderTool(item.raw["toolName"]?.string),
              let reference = Self.reference(in: item.raw["output"], depth: 0) else { return nil }
        self.init(reference: reference)
    }

    /// Helm's own tool under any provider's naming: `mcp__t3-code__html_render`, `t3-code.html_render`,
    /// `t3-code-thread_1_html_render`, or bare `html_render`. Another server's `html_render` is not ours.
    static func isRenderTool(_ name: String?) -> Bool {
        guard let name else { return false }
        if name == "html_render" { return true }
        let ours = ["mcp__t3-code__", "mcp__t3_code__", "t3-code", "t3_code"].contains { name.hasPrefix($0) }
        return ours && ["__html_render", ".html_render", "_html_render"].contains { name.hasSuffix($0) }
    }

    /// Providers wrap a tool's result differently: a JSON string, MCP `content` text blocks, or
    /// `structuredContent`. An error result carries no page.
    private static func reference(in value: JSON?, depth: Int) -> JSON? {
        guard let value, depth < 6 else { return nil }
        switch value {
        case .string(let text):
            guard text.contains("htmlRender"), let data = text.data(using: .utf8), let parsed = try? JSON.parse(data),
                  parsed.string == nil else { return nil }
            return reference(in: parsed, depth: depth + 1)
        case .array(let entries):
            for entry in entries {
                if let found = reference(in: entry["text"] ?? entry, depth: depth + 1) { return found }
            }
            return nil
        case .object(let object):
            if object["isError"]?.bool == true || object["is_error"]?.bool == true { return nil }
            if let render = object["htmlRender"]?.object { return .object(render) }
            return reference(in: object["structuredContent"] ?? object["content"], depth: depth + 1)
        default:
            return nil
        }
    }

    /// The frame's height at `width`, like the desktop's `htmlRenderFrameHeight`: what the Mac
    /// measured at the nearest widths, or the page's own height once it has reported one.
    func frameHeight(width: Double, contentHeight: Double? = nil) -> Double {
        guard !heights.isEmpty else { return Self.clamp(min(height, contentHeight ?? height)) }
        let cap = measured(at: Self.columnWidth) > height ? height : Self.maxHeight
        return Self.clamp(min(cap, contentHeight ?? measured(at: width)))
    }

    /// The taller of the heights measured at the nearest widths on each side.
    private func measured(at width: Double) -> Double {
        let high = heights.firstIndex { $0.width >= width } ?? heights.count - 1
        let low = heights[high].width == width ? high : max(0, high - 1)
        return max(heights[low].height, heights[high].height)
    }

    static func clamp(_ height: Double) -> Double {
        min(maxHeight, max(minHeight, height.rounded()))
    }

    var fileName: String {
        let name = title.components(separatedBy: CharacterSet(charactersIn: "\\/:*?\"<>|").union(.controlCharacters))
            .joined(separator: " ")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return "\(name.isEmpty ? "Page" : String(name.prefix(120)))" + ".html"
    }
}
