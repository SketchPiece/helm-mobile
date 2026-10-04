import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// "Helm" in the share sheet. Copies what was shared into the App Group (`ShareInbox`), then opens
/// Helm, which starts a new thread with it. When iOS doesn't let the extension open the app, it
/// says the share is saved and Helm picks it up the next time it comes forward.
final class ShareViewController: UIViewController {
    private let state = ShareState()

    override func viewDidLoad() {
        super.viewDidLoad()
        let host = UIHostingController(rootView: ShareCard(state: state) { [weak self] in self?.close() })
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
        Task { await save() }
    }

    private func save() async {
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        do {
            guard let root = ShareInbox.root else { throw ShareError.noContainer }
            let folder = try ShareInbox.makeFolder(in: root)
            var manifest = ShareInbox.Manifest(createdAt: Date())
            for provider in providers {
                await collect(provider, into: folder, manifest: &manifest)
            }
            guard !manifest.isEmpty else {
                try? FileManager.default.removeItem(at: folder)
                throw ShareError.nothingUsable
            }
            try ShareInbox.finish(manifest, in: folder)
        } catch {
            state.phase = .failed(error.localizedDescription)
            return
        }
        if await openHelm() {
            close()
        } else {
            state.phase = .saved
        }
    }

    // MARK: Reading items

    /// Adds one shared item to the manifest: links and text as text, everything else as a file.
    private func collect(_ provider: NSItemProvider, into folder: URL, manifest: inout ShareInbox.Manifest) async {
        let types = provider.registeredContentTypes
        if types.contains(where: { $0.conforms(to: .url) && !$0.conforms(to: .fileURL) }) && !types.contains(where: { $0.conforms(to: .fileURL) }) {
            if let url = await load(URL.self, from: provider) { manifest.texts.append(url.absoluteString) }
            return
        }
        let isText = types.contains { $0.conforms(to: .text) }
        let isFile = provider.suggestedName != nil || types.contains { $0.conforms(to: .fileURL) }
        if isText && !isFile {
            if let text = await load(String.self, from: provider) { manifest.texts.append(text) }
            return
        }
        // A picture in a type providers take as is, else any picture, else whatever data it has.
        let isImage = types.contains { $0.conforms(to: .image) }
        let preferred: [UTType] = [.jpeg, .png, .gif, .webP]
        guard let type = types.first(where: { preferred.contains($0) })
            ?? types.first(where: { isImage ? $0.conforms(to: .image) : $0.conforms(to: .data) })
        else { return }
        let suggested = provider.suggestedName.map { name in
            name.contains(".") || type.preferredFilenameExtension == nil ? name : "\(name).\(type.preferredFilenameExtension!)"
        }
        let existing = manifest.files.map(\.name)
        let fallback = "shared-\(isImage ? "image" : "file")-\(existing.count + 1)"
        guard let name = await copy(provider, type: type, into: folder, suggested: suggested, fallback: fallback, existing: existing)
        else { return }
        manifest.files.append(.init(name: name, isImage: isImage))
    }

    private func load<T: _ObjectiveCBridgeable & Sendable>(_ type: T.Type, from provider: NSItemProvider) async -> T?
        where T._ObjectiveCType: NSItemProviderReading
    {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: type) { value, _ in continuation.resume(returning: value) }
        }
    }

    /// Copies the item's file into the share's folder; returns the name it got.
    private func copy(
        _ provider: NSItemProvider, type: UTType, into folder: URL, suggested: String?, fallback: String, existing: [String]
    ) async -> String? {
        await withCheckedContinuation { continuation in
            _ = provider.loadFileRepresentation(for: type, openInPlace: false) { url, _, _ in
                guard let url else { return continuation.resume(returning: nil) }
                var raw = suggested ?? url.lastPathComponent
                if raw.isEmpty || raw.hasPrefix(".") { raw = fallback + (type.preferredFilenameExtension.map { ".\($0)" } ?? "") }
                let name = ShareInbox.uniqueName(String(raw.replacingOccurrences(of: "/", with: "-").prefix(200)), existing: existing)
                do {
                    try FileManager.default.copyItem(at: url, to: folder.appending(path: name))
                    continuation.resume(returning: name)
                } catch {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    // MARK: Leaving

    /// Asks iOS to bring Helm forward. Share extensions have no supported way to do this, so after
    /// the extension context it walks the responder chain to the host application, as the React
    /// Native client's share extension does; false when neither works.
    private func openHelm() async -> Bool {
        if await extensionContext?.open(ShareInbox.openURL) == true { return true }
        var responder: UIResponder? = self
        while let current = responder {
            if let application = current as? UIApplication {
                return await application.open(ShareInbox.openURL)
            }
            responder = current.next
        }
        return false
    }

    private func close() {
        extensionContext?.completeRequest(returningItems: nil)
    }
}

private enum ShareError: LocalizedError {
    case noContainer, nothingUsable

    var errorDescription: String? {
        switch self {
        case .noContainer: String(localized: "Helm can't save shared items in this build.")
        case .nothingUsable: String(localized: "There's nothing here Helm can use.")
        }
    }
}

@MainActor
@Observable
final class ShareState {
    enum Phase: Equatable { case saving, saved, failed(String) }
    var phase = Phase.saving
}

/// The extension's only screen: a short wait, then "saved" (when Helm couldn't be opened) or an error.
struct ShareCard: View {
    let state: ShareState
    let done: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            switch state.phase {
            case .saving:
                ProgressView().controlSize(.large)
                Text("Saving for Helm…").font(Typography.body).foregroundStyle(Palette.textMuted)
            case .saved:
                symbol("checkmark.circle.fill", Palette.text)
                Text("Saved").font(Typography.headline).foregroundStyle(Palette.text)
                Text("Open Helm to start the thread.").font(Typography.subheadline).foregroundStyle(Palette.textMuted)
                doneButton
            case .failed(let message):
                symbol("exclamationmark.triangle.fill", Palette.errorText)
                Text("Couldn't share to Helm").font(Typography.headline).foregroundStyle(Palette.text)
                Text(message).font(Typography.subheadline).foregroundStyle(Palette.textMuted)
                doneButton
            }
        }
        .multilineTextAlignment(.center)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.canvas)
        .tint(Palette.text)
    }

    private func symbol(_ name: String, _ color: Color) -> some View {
        Image(systemName: name).font(.system(size: 44)).foregroundStyle(color)
    }

    private var doneButton: some View {
        Button(action: done) {
            Text("Done").font(Typography.headline).frame(maxWidth: 240).padding(.vertical, 6)
        }
        .buttonStyle(.glass)
        .padding(.top, 6)
        .accessibilityIdentifier("shareDone")
    }
}
