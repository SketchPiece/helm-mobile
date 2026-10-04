import Foundation
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// An image or file picked in the composer, uploaded as soon as it is picked.
struct DraftAttachment: Identifiable, Equatable {
    let id = UUID()
    var preview: UIImage?
    var name: String
    var isImage = true
    var sizeBytes: Int?
    var uploaded: ChatAttachment?
    var failed: String?

    var isUploading: Bool { uploaded == nil && failed == nil }
    /// Identity of the file's context record and its inline `t3-context://` link.
    var contextId: String { id.uuidString.lowercased() }
}

extension EnvironmentSession {
    /// `attachments.createUploadUrl`, then a raw POST of the bytes to the signed URL.
    func upload(data: Data, name: String, mimeType: String, type: String) async throws -> ChatAttachment {
        var payload: [String: JSON] = [
            "name": .string(name), "mimeType": .string(mimeType), "sizeBytes": .number(Double(data.count)),
        ]
        if type != "image" { payload["type"] = .string(type) }
        // Attaching often follows a switch from another app (copy there, paste here), while the
        // socket is still reconnecting: wait for it, and retry once if it drops mid-call.
        let result: JSON
        do {
            try await waitUntilLive()
            result = try await call("attachments.createUploadUrl", .object(payload))
        } catch RPCError.disconnected, RPCError.timedOut {
            try await waitUntilLive()
            result = try await call("attachments.createUploadUrl", .object(payload))
        }
        guard let id = result["attachmentId"]?.string, let relative = result["relativeUrl"]?.string else {
            throw RPCError.defect("No upload URL")
        }
        var request = URLRequest(url: http.url(relative))
        request.httpMethod = "POST"
        request.setValue(mimeType, forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120
        let (_, response) = try await HelmHTTP.session.upload(for: request, from: data)
        guard let status = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status) else {
            throw HelmHTTPError.status((response as? HTTPURLResponse)?.statusCode ?? 0, "Upload failed")
        }
        return ChatAttachment(id: id, type: type, name: name, mimeType: mimeType, sizeBytes: data.count)
    }

    /// Images go up as JPEG, at most 2048 px on the long side (the server takes gif/jpeg/png/webp ≤ 10 MB).
    func uploadImage(_ image: UIImage, name: String = "photo.jpg") async throws -> ChatAttachment {
        let data = await Task.detached(priority: .userInitiated) { () -> Data? in
            let maxSide: CGFloat = 2048
            let size = image.size
            let scale = min(1, maxSide / max(size.width, size.height))
            let target = CGSize(width: floor(size.width * scale), height: floor(size.height * scale))
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let resized = UIGraphicsImageRenderer(size: target, format: format).image { _ in
                image.draw(in: CGRect(origin: .zero, size: target))
            }
            return resized.jpegData(compressionQuality: 0.85)
        }.value
        guard let data else { throw RPCError.defect("Couldn't read the image") }
        return try await upload(data: data, name: name, mimeType: "image/jpeg", type: "image")
    }
}

/// Unsent composer text per thread, so leaving a thread doesn't lose a half-written message.
enum Drafts {
    static func text(for key: String) -> String {
        UserDefaults.standard.string(forKey: "draft.\(key)") ?? ""
    }

    static func save(_ text: String, for key: String) {
        if text.isEmpty {
            UserDefaults.standard.removeObject(forKey: "draft.\(key)")
        } else {
            UserDefaults.standard.set(text, forKey: "draft.\(key)")
        }
    }
}

/// What a composer holds besides its text: attachments (uploaded as soon as they are picked),
/// pull requests picked from `#` and threads picked from `@`. Shared by the thread and new-thread composers.
@MainActor
@Observable
final class ComposerDraft {
    private(set) var attachments: [DraftAttachment] = []
    private(set) var pullRequests: [PullRequestReference] = []
    private(set) var threads: [ThreadReference] = []
    /// Why the last attach or paste didn't go through; cleared by the next one.
    var notice: String?

    var isUploading: Bool { attachments.contains(where: \.isUploading) }
    var hasUploaded: Bool { attachments.contains { $0.uploaded != nil } }

    /// Full pictures behind pasted and photographed tiles, so a failed upload can be retried.
    @ObservationIgnored private var images: [UUID: UIImage] = [:]

    func remove(_ id: UUID) {
        attachments.removeAll { $0.id == id }
        images[id] = nil
    }

    /// A tap on a failed tile: uploads the picture again when it is still at hand, otherwise says why it failed.
    func retry(_ id: UUID, environment: EnvironmentSession) {
        guard let attachment = attachments.first(where: { $0.id == id }), let failed = attachment.failed else { return }
        guard let image = images[id] else {
            notice = "\(attachment.name): \(failed)"
            return
        }
        notice = nil
        update(id) { $0.failed = nil }
        upload(image, id: id, name: (attachment.name as NSString).deletingPathExtension, environment: environment)
    }

    func reset() {
        attachments = []
        images = [:]
        pullRequests = []
        threads = []
        notice = nil
    }

    private var contextCount: Int { attachments.count + pullRequests.count + threads.count }

    func addPullRequest(_ reference: PullRequestReference) {
        pullRequests.removeAll { $0.number == reference.number }
        guard contextCount < AttachmentLimits.maxContextRecords else {
            notice = String(localized: "Too many attachments and links in one message")
            return
        }
        pullRequests.append(reference)
    }

    /// Returns false when the message already carries too many records to take another.
    @discardableResult
    func addThread(_ reference: ThreadReference) -> Bool {
        guard !threads.contains(where: { $0.threadId == reference.threadId }) else { return true }
        guard contextCount < AttachmentLimits.maxContextRecords else {
            notice = String(localized: "Too many attachments and links in one message")
            return false
        }
        threads.append(reference)
        return true
    }

    /// Finished uploads with the context id of their record and link.
    var uploaded: [(contextId: String, attachment: ChatAttachment)] {
        attachments.compactMap { draft in draft.uploaded.map { (draft.contextId, $0) } }
    }

    /// The text, attachments and context records for one send. Uploads still running or failed are left out.
    func message(text: String, inlineContext: Bool) -> ComposerMessage {
        return ComposerMessage.build(text: text, attachments: uploaded, pullRequests: pullRequests, threads: threads,
                                     inlineContext: inlineContext)
    }

    // MARK: Attaching

    func attach(_ item: PhotosPickerItem, environment: EnvironmentSession) {
        if item.supportedContentTypes.contains(where: { $0.conforms(to: .movie) }) {
            attach(video: item, environment: environment)
            return
        }
        guard let id = begin(DraftAttachment(name: "photo.jpg")) else { return }
        Task {
            do {
                guard let data = try await item.loadTransferable(type: Data.self), let image = UIImage(data: data) else {
                    throw RPCError.defect(String(localized: "Couldn't read the photo"))
                }
                update(id) { $0.preview = image.preparingThumbnail(of: CGSize(width: 160, height: 160)) }
                let uploaded = try await environment.uploadImage(image, name: "photo-\(Int(Date().timeIntervalSince1970)).jpg")
                finish(id, uploaded)
            } catch {
                update(id) { $0.failed = error.localizedDescription }
            }
        }
    }

    /// A video from the photo library goes up as a file (copied out of Photos first).
    private func attach(video item: PhotosPickerItem, environment: EnvironmentSession) {
        Task {
            do {
                guard let movie = try await item.loadTransferable(type: PickedMovie.self) else {
                    throw RPCError.defect(String(localized: "Couldn't read the video"))
                }
                attach(fileURLs: [movie.url], environment: environment)
            } catch {
                notice = error.localizedDescription
            }
        }
    }

    /// A pasted or photographed picture; `name` is the file name's stem.
    func attach(image: UIImage, environment: EnvironmentSession, name: String = "image") {
        var draft = DraftAttachment(name: "\(name).jpg")
        draft.preview = image.preparingThumbnail(of: CGSize(width: 160, height: 160))
        guard let id = begin(draft) else { return }
        images[id] = image
        upload(image, id: id, name: name, environment: environment)
    }

    private func upload(_ image: UIImage, id: UUID, name: String, environment: EnvironmentSession) {
        Task {
            do {
                finish(id, try await environment.uploadImage(image, name: "\(name)-\(Int(Date().timeIntervalSince1970)).jpg"))
                images[id] = nil
            } catch {
                update(id) { $0.failed = error.localizedDescription }
            }
        }
    }

    /// Files from the document picker. Gif/jpeg/png/webp go up as images, everything else as files.
    func attach(fileURLs urls: [URL], environment: EnvironmentSession) {
        for url in urls {
            let rawName = String(url.lastPathComponent.prefix(255))
            let name = rawName.trimmingCharacters(in: .whitespaces).isEmpty ? "file" : rawName
            let declared = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            let imageMime = AttachmentLimits.imageMimeType(name: name, mimeType: declared)
            let size = Self.fileSize(url)
            if let problem = admission(isImage: imageMime != nil, size: size, config: environment.config) {
                notice = "\(name): \(problem)"
                continue
            }
            var draft = DraftAttachment(name: name)
            draft.isImage = imageMime != nil
            draft.sizeBytes = size
            guard let id = begin(draft) else { return }
            Task {
                do {
                    let data = try await Self.read(url)
                    if let imageMime, let image = UIImage(data: data) {
                        update(id) { $0.preview = image.preparingThumbnail(of: CGSize(width: 160, height: 160)) }
                        // Oversized pictures are re-encoded rather than refused.
                        let uploaded = data.count <= AttachmentLimits.maxImageBytes
                            ? try await environment.upload(data: data, name: name, mimeType: imageMime, type: "image")
                            : try await environment.uploadImage(image, name: name)
                        finish(id, uploaded)
                    } else {
                        let mime = String(declared.prefix(100))
                        finish(id, try await environment.upload(data: data, name: name, mimeType: mime, type: "file"))
                    }
                } catch {
                    update(id) { $0.failed = error.localizedDescription }
                }
            }
        }
    }

    /// Files shared from other apps. Pictures in a type providers don't take (HEIC from Photos) are
    /// re-encoded as JPEG; everything else goes through `attach(fileURLs:)`.
    func attach(shared files: [SharedFile], environment: EnvironmentSession) {
        for file in files {
            let name = file.url.lastPathComponent
            let declared = UTType(filenameExtension: file.url.pathExtension)?.preferredMIMEType ?? ""
            if file.isImage, AttachmentLimits.imageMimeType(name: name, mimeType: declared) == nil,
               let image = UIImage(contentsOfFile: file.url.path)
            {
                attach(image: image, environment: environment)
            } else {
                attach(fileURLs: [file.url], environment: environment)
            }
        }
    }

    /// Long pasted text as `pasted-text[-N].txt`, which the agent reads instead of getting inline.
    func attach(pastedText text: String, environment: EnvironmentSession) {
        let name = PastedText.nextFileName(existing: attachments.map(\.name))
        let data = Data(text.utf8)
        var draft = DraftAttachment(name: name)
        draft.isImage = false
        draft.sizeBytes = data.count
        guard let id = begin(draft) else { return }
        Task {
            do {
                var uploaded = try await environment.upload(data: data, name: name, mimeType: PastedText.mimeType, type: "file")
                uploaded.source = "pasted-text"
                finish(id, uploaded)
            } catch {
                update(id) { $0.failed = error.localizedDescription }
            }
        }
    }

    // MARK: Paste

    /// The clipboard into the composer: an image is attached, long text becomes a file, and short
    /// text comes back for the caller to insert.
    func paste(environment: EnvironmentSession, draftLength: Int) -> String? {
        notice = nil
        let board = UIPasteboard.general
        if board.hasImages, let image = board.image {
            attach(image: image, environment: environment)
            return nil
        }
        guard let text = board.string, !text.isEmpty else {
            notice = String(localized: "Nothing to paste")
            return nil
        }
        return place(text, draftLength: draftLength, environment: environment)
    }

    /// Called on every text change: a big jump is a paste, and one over the threshold is moved
    /// into a file. Returns the text to put back, or nil to keep the edit.
    func foldPaste(old: String, new: String, environment: EnvironmentSession?) -> String? {
        let grown = new.utf16.count - old.utf16.count
        guard grown >= 8_000 || (grown > 0 && new.utf16.count > AttachmentLimits.maxMessageChars) else { return nil }
        let (range, inserted) = PastedText.insertion(from: old, to: new)
        let rest = (new as NSString).replacingCharacters(in: range, with: "")
        guard let environment else { return nil }
        return place(inserted, draftLength: rest.utf16.count, environment: environment) == nil ? rest : nil
    }

    /// Decides where pasted text goes: returns it when it stays inline, nil when it became a file
    /// or was refused (with a notice).
    private func place(_ text: String, draftLength: Int, environment: EnvironmentSession) -> String? {
        let maxBytes = environment.config?.maxFileBytes
        let canAttach = maxBytes.map { text.utf8.count <= $0 } == true && attachments.count < AttachmentLimits.maxPerMessage
        if PastedText.shouldAttach(text, draftLength: draftLength, canAttach: canAttach) {
            attach(pastedText: text, environment: environment)
            return nil
        }
        if draftLength + text.utf16.count > AttachmentLimits.maxMessageChars {
            notice = String(localized: "That's too much text for one message")
            return nil
        }
        return text
    }

    // MARK: Bookkeeping

    /// Why a file can't be attached, or nil when it can.
    private func admission(isImage: Bool, size: Int?, config: ServerConfig?) -> String? {
        if attachments.count >= AttachmentLimits.maxPerMessage {
            return String(localized: "Up to 100 attachments per message")
        }
        if size == 0 { return String(localized: "The file is empty") }
        if isImage { return nil }  // pictures over 10 MB are re-encoded
        guard let limit = config?.maxFileBytes else { return String(localized: "This Mac doesn't take files") }
        if let size, size > limit {
            return String(localized: "Larger than \(ByteCountFormatter.string(fromByteCount: Int64(limit), countStyle: .file))")
        }
        return nil
    }

    private func begin(_ draft: DraftAttachment) -> UUID? {
        guard attachments.count < AttachmentLimits.maxPerMessage else {
            notice = String(localized: "Up to 100 attachments per message")
            return nil
        }
        notice = nil
        attachments.append(draft)
        return draft.id
    }

    private func finish(_ id: UUID, _ uploaded: ChatAttachment) {
        let imageBytes = attachments.compactMap { $0.uploaded }.filter(\.isImage).reduce(0) { $0 + $1.sizeBytes }
        if uploaded.isImage, imageBytes + uploaded.sizeBytes > AttachmentLimits.maxImageBytesPerMessage {
            update(id) { $0.failed = String(localized: "Pictures in one message can't pass 80 MB") }
            return
        }
        update(id) {
            $0.uploaded = uploaded
            $0.sizeBytes = uploaded.sizeBytes
        }
    }

    private func update(_ id: UUID, _ change: (inout DraftAttachment) -> Void) {
        if let index = attachments.firstIndex(where: { $0.id == id }) { change(&attachments[index]) }
    }

    private static func fileSize(_ url: URL) -> Int? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
    }

    private static func read(_ url: URL) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            return try Data(contentsOf: url, options: .mappedIfSafe)
        }.value
    }
}

/// A video handed over by the photo picker, copied into a temporary folder of its own (the
/// picker's copy goes away once the import returns).
struct PickedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            let folder = FileManager.default.temporaryDirectory
                .appending(path: "picked-videos/\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appending(path: received.file.lastPathComponent)
            try FileManager.default.copyItem(at: received.file, to: url)
            return PickedMovie(url: url)
        }
    }
}
