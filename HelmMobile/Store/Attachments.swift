import Foundation
import UIKit

/// An image or file picked in the composer, uploaded as soon as it is picked.
struct DraftAttachment: Identifiable, Equatable {
    let id = UUID()
    var preview: UIImage?
    var name: String
    var uploaded: ChatAttachment?
    var failed: String?

    var isUploading: Bool { uploaded == nil && failed == nil }
}

extension EnvironmentSession {
    /// `attachments.createUploadUrl`, then a raw POST of the bytes to the signed URL.
    func upload(data: Data, name: String, mimeType: String, type: String) async throws -> ChatAttachment {
        var payload: [String: JSON] = [
            "name": .string(name), "mimeType": .string(mimeType), "sizeBytes": .number(Double(data.count)),
        ]
        if type != "image" { payload["type"] = .string(type) }
        let result = try await call("attachments.createUploadUrl", .object(payload))
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
