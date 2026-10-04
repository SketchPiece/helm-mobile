import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// A proposed plan as a Markdown file: named after its first heading, as the desktop names it
/// (`proposedPlan.ts`).
struct PlanExport: Transferable {
    let markdown: String

    /// The first heading, if the plan has one.
    var title: String? {
        guard let match = markdown.firstMatch(of: /(?m)^\s{0,3}#{1,6}\s+(.+)$/) else { return nil }
        let title = match.output.1.trimmingCharacters(in: .whitespaces)
        return title.isEmpty ? nil : title
    }

    /// "fix-login-redirect.md".
    var filename: String {
        let slug = (title ?? "plan").lowercased()
            .replacing(/[`'".,!?()\[\]{}]+/, with: "")
            .replacing(/[^a-z0-9]+/, with: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return "\(slug.isEmpty ? "plan" : slug).md"
    }

    var contents: String {
        var trimmed = markdown
        while trimmed.last?.isWhitespace == true { trimmed.removeLast() }
        return trimmed + "\n"
    }

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: UTType("net.daringfireball.markdown") ?? .utf8PlainText) { plan in
            Data(plan.contents.utf8)
        }
        .suggestedFileName { $0.filename }
    }
}
