import PhotosUI
import SwiftUI

/// The Mac remote's camera button: the latest screenshot, already picked, and the ones before it.
/// Send puts it in the thread now; "Add a few words" keeps it for what is said next.
struct ScreenshotPanel: View {
    let remote: MacRemote
    @Environment(\.dismiss) private var dismiss
    @State private var screenshots = RecentScreenshots()
    @State private var selection: String?
    @State private var picked: PhotosPickerItem?
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(caption)
                    .font(Typography.mono(12))
                    .foregroundStyle(Palette.textMuted)
                Spacer()
                PhotosPicker(selection: $picked, matching: .images) {
                    Text("All photos").font(Typography.footnote.weight(.medium))
                }
                .foregroundStyle(Palette.accentText)
            }
            preview
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if screenshots.shots.count > 1 { strip }
            HStack(spacing: 10) {
                Button {
                    Task { await take(sendNow: false) }
                } label: {
                    Label("Add a few words", systemImage: "mic.fill")
                        .font(Typography.subheadline.weight(.medium))
                        .frame(maxWidth: .infinity, minHeight: 48)
                }
                .buttonStyle(.glass)
                Button {
                    Task { await take(sendNow: true) }
                } label: {
                    Group {
                        if working { ProgressView().tint(Palette.accentForeground) } else { Text("Send") }
                    }
                    .font(Typography.subheadline.weight(.semibold))
                    .foregroundStyle(Palette.accentForeground)
                    .frame(maxWidth: .infinity, minHeight: 48)
                }
                .buttonStyle(.glassProminent)
                .tint(Palette.accent)
            }
            .disabled(selected == nil || working)
        }
        .padding(16)
        .background(Palette.canvas)
        .presentationDragIndicator(.visible)
        .task {
            await screenshots.load()
            selection = screenshots.shots.first?.id
        }
        .onChange(of: picked) {
            guard let picked else { return }
            Task {
                if let data = try? await picked.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                    remote.pendingScreenshot = image
                    dismiss()
                }
            }
        }
    }

    private var selected: RecentScreenshots.Shot? { screenshots.shots.first { $0.id == selection } }

    private var caption: String {
        guard let date = selected?.createdAt else { return String(localized: "SCREENSHOTS") }
        return String(localized: "SCREENSHOT · \(RelativeTime.short(date).uppercased())")
    }

    @ViewBuilder
    private var preview: some View {
        if let selected, let image = screenshots.thumbnails[selected.id] {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .clipShape(.rect(cornerRadius: 18))
                .overlay(RoundedRectangle(cornerRadius: 18).stroke(Palette.border))
        } else if screenshots.denied {
            ContentUnavailableView("No access to photos", systemImage: "photo.badge.exclamationmark",
                                   description: Text("Allow Helm to see your photos in Settings, or pick one under All photos."))
        } else if screenshots.loaded, screenshots.shots.isEmpty {
            ContentUnavailableView("No screenshots yet", systemImage: "camera.viewfinder",
                                   description: Text("Take one with the side and volume up buttons."))
        } else {
            ProgressView()
        }
    }

    private var strip: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 10) {
                ForEach(screenshots.shots) { shot in
                    Button {
                        selection = shot.id
                    } label: {
                        Group {
                            if let image = screenshots.thumbnails[shot.id] {
                                Image(uiImage: image).resizable().scaledToFill()
                            } else {
                                Palette.surface
                            }
                        }
                        .frame(width: 62, height: 110)
                        .clipShape(.rect(cornerRadius: 10))
                        .overlay {
                            if shot.id == selection {
                                RoundedRectangle(cornerRadius: 10).stroke(Palette.accent, lineWidth: 2.5).padding(-3)
                            }
                        }
                        .opacity(shot.id == selection ? 1 : 0.75)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(4)
        }
        .scrollIndicators(.hidden)
    }

    private func take(sendNow: Bool) async {
        guard let selected, !working else { return }
        working = true
        defer { working = false }
        guard let image = await screenshots.fullImage(selected) else { return }
        if sendNow {
            await remote.sendScreenshot(image)
        } else {
            remote.pendingScreenshot = image
        }
        dismiss()
    }
}
