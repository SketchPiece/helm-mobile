import PhotosUI
import SwiftUI

/// The composer's "+": photos, files from the Files app, or whatever is on the clipboard.
struct AttachMenu: View {
    let draft: ComposerDraft
    let environment: EnvironmentSession?
    var size: CGFloat = 36
    let onPaste: () -> Void

    @State private var showPhotos = false
    @State private var showFiles = false
    @State private var photoItems: [PhotosPickerItem] = []

    var body: some View {
        Menu {
            Button {
                showPhotos = true
            } label: { Label("Photos", systemImage: "photo.on.rectangle") }
            if environment?.config?.maxFileBytes != nil {
                Button {
                    showFiles = true
                } label: { Label("Files", systemImage: "folder") }
            }
            Button(action: onPaste) { Label("Paste", systemImage: "doc.on.clipboard") }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 17, weight: .medium))
                .frame(width: size, height: size)
                .contentShape(.circle)
        }
        .foregroundStyle(Palette.text)
        .accessibilityLabel("Attach")
        .accessibilityIdentifier("attach")
        .photosPicker(isPresented: $showPhotos, selection: $photoItems, maxSelectionCount: 6, matching: .images)
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            guard let environment, case .success(let urls) = result else { return }
            draft.attach(fileURLs: urls, environment: environment)
        }
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty, let environment else { return }
            photoItems = []
            for item in items { draft.attach(item, environment: environment) }
        }
    }
}

/// Picked photos as tiles and files as chips (name and size), each removable.
struct AttachmentStrip: View {
    let draft: ComposerDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let notice = draft.notice {
                Text(notice)
                    .font(Typography.footnote)
                    .foregroundStyle(Palette.errorText)
                    .padding(.horizontal, 8)
                    .onTapGesture { draft.notice = nil }
            }
            if !draft.attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(draft.attachments) { attachment in
                            Group {
                                if attachment.isImage { imageTile(attachment) } else { fileChip(attachment) }
                            }
                            .overlay(alignment: .topTrailing) {
                                Button {
                                    draft.remove(attachment.id)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .symbolRenderingMode(.palette)
                                        .foregroundStyle(.white, .black.opacity(0.6))
                                        .font(.system(size: 18))
                                }
                                .accessibilityLabel("Remove \(attachment.name)")
                                .offset(x: 5, y: -5)
                            }
                        }
                    }
                    .padding(.top, 6)
                    .padding(.horizontal, 6)
                }
            }
        }
    }

    private func imageTile(_ attachment: DraftAttachment) -> some View {
        ZStack {
            Palette.surface
            if let preview = attachment.preview {
                Image(uiImage: preview).resizable().scaledToFill()
            }
            if attachment.isUploading {
                Color.black.opacity(0.3)
                ProgressView().tint(.white)
            } else if attachment.failed != nil {
                Color.black.opacity(0.4)
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.errorText)
            }
        }
        .frame(width: 64, height: 64)
        .clipShape(.rect(cornerRadius: 12, style: .continuous))
    }

    private func fileChip(_ attachment: DraftAttachment) -> some View {
        HStack(spacing: 8) {
            Group {
                if attachment.isUploading {
                    ProgressView()
                } else if attachment.failed != nil {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.errorText)
                } else {
                    Image(systemName: attachment.uploaded?.source == "pasted-text" ? "doc.plaintext" : "doc")
                        .foregroundStyle(Palette.textMuted)
                }
            }
            .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(attachment.name)
                    .font(Typography.footnote.weight(.medium))
                    .foregroundStyle(Palette.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(attachment.failed ?? attachment.sizeBytes.map {
                    ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file)
                } ?? "")
                .font(Typography.caption)
                .foregroundStyle(attachment.failed == nil ? Palette.textMuted : Palette.errorText)
                .lineLimit(1)
            }
            .frame(maxWidth: 160, alignment: .leading)
        }
        .padding(.leading, 10)
        .padding(.trailing, 14)
        .frame(height: 64)
        .background(Palette.surface, in: .rect(cornerRadius: 12, style: .continuous))
    }
}

/// Suggestions for the token being typed, above the composer: up to five rows, then it scrolls.
struct SuggestionPanel: View {
    let suggestions: ComposerSuggestions
    let onPick: (ComposerSuggestions.Item) -> Void
    @ScaledMetric(relativeTo: .body) private var rowHeight: CGFloat = 52

    var body: some View {
        let rows = VStack(spacing: 0) {
            ForEach(suggestions.items) { item in
                Button {
                    onPick(item)
                } label: {
                    row(item)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("suggestion")
            }
            if suggestions.items.isEmpty {
                HStack(spacing: 10) {
                    if suggestions.isLoading { ProgressView() }
                    Text(suggestions.message ?? String(localized: "Searching…"))
                        .font(Typography.footnote)
                        .foregroundStyle(Palette.textMuted)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .frame(minHeight: rowHeight)
            }
        }
        Group {
            if suggestions.items.count > 5 {
                ScrollView { rows }
                    .frame(height: rowHeight * 5.5)
            } else {
                rows
            }
        }
        .clipShape(.rect(cornerRadius: 18, style: .continuous))
        .floatingSurface(cornerRadius: 18)
    }

    private func row(_ item: ComposerSuggestions.Item) -> some View {
        HStack(spacing: 12) {
            Image(systemName: item.symbol)
                .font(.system(size: 15))
                .foregroundStyle(Palette.textMuted)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(item.title.hasPrefix("/") || item.title.hasPrefix("#") ? Typography.mono(15, relativeTo: .body) : Typography.body)
                    .foregroundStyle(Palette.text)
                    .lineLimit(1)
                if !item.detail.isEmpty {
                    Text(item.detail)
                        .font(Typography.footnote)
                        .foregroundStyle(Palette.textMuted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .frame(height: rowHeight)
        .contentShape(.rect)
    }
}
