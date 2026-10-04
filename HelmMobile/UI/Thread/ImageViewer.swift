import SwiftUI
import UIKit

/// The images of one message, full screen: swipe between them, pinch or double-tap to zoom,
/// drag down to close, share the one on screen.
struct ImageViewer: View {
    let attachments: [ChatAttachment]
    let environment: EnvironmentSession
    @State var selection: String
    @Environment(\.dismiss) private var dismiss
    @State private var images: [String: UIImage] = [:]
    @State private var failed: Set<String> = []
    @State private var dragOffset: CGFloat = 0
    @State private var zoomed = false

    var body: some View {
        TabView(selection: $selection) {
            ForEach(attachments) { attachment in
                page(attachment)
                    .tag(attachment.id)
                    .task { await load(attachment) }
            }
        }
        .tabViewStyle(.page(indexDisplayMode: attachments.count > 1 ? .automatic : .never))
        .offset(y: dragOffset)
        .background(Color.black.opacity(1 - min(0.6, abs(dragOffset) / 600)).ignoresSafeArea())
        // Drag down to close, unless the image is zoomed in and the drag pans it.
        .simultaneousGesture(
            DragGesture(minimumDistance: 20)
                .onChanged { value in
                    guard !zoomed, value.translation.height > abs(value.translation.width) else { return }
                    dragOffset = max(0, value.translation.height)
                }
                .onEnded { value in
                    guard !zoomed else { return }
                    if dragOffset > 120 || value.predictedEndTranslation.height > 400 {
                        dismiss()
                    } else {
                        withAnimation(.snappy(duration: 0.25)) { dragOffset = 0 }
                    }
                }
        )
        .overlay(alignment: .top) { chrome }
        .statusBarHidden()
        .onChange(of: selection) { zoomed = false }
    }

    @ViewBuilder
    private func page(_ attachment: ChatAttachment) -> some View {
        if let image = images[attachment.id] {
            ZoomableImage(image: image, zoomed: selection == attachment.id ? $zoomed : .constant(false))
                .ignoresSafeArea()
                .accessibilityLabel(Text(attachment.name))
        } else if failed.contains(attachment.id) {
            ContentUnavailableView("Couldn't load the image", systemImage: "photo.badge.exclamationmark")
                .foregroundStyle(.white)
        } else {
            ProgressView().tint(.white).controlSize(.large)
        }
    }

    private var chrome: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 40, height: 40)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .accessibilityLabel("Close")
            .accessibilityIdentifier("closeImageViewer")
            Spacer()
            if attachments.count > 1, let index = attachments.firstIndex(where: { $0.id == selection }) {
                Text("\(index + 1) of \(attachments.count)")
                    .font(Typography.footnote.weight(.medium))
                    .monospacedDigit()
                    .padding(.horizontal, 12)
                    .frame(height: 32)
                    .glassEffect(.regular, in: .capsule)
            }
            Spacer()
            if let image = images[selection] {
                ShareLink(item: Image(uiImage: image),
                          preview: SharePreview(attachments.first { $0.id == selection }?.name ?? "", image: Image(uiImage: image))) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 40, height: 40)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .accessibilityLabel("Share")
            } else {
                Color.clear.frame(width: 40, height: 40)
            }
        }
        .padding(.horizontal, 16)
        .opacity(dragOffset > 0 ? 0 : 1)
        .environment(\.colorScheme, .dark)
    }

    private func load(_ attachment: ChatAttachment) async {
        guard images[attachment.id] == nil else { return }
        if let image = await AttachmentLoader.fullImage(attachment, environment: environment) {
            images[attachment.id] = image
        } else {
            failed.insert(attachment.id)
        }
    }
}

/// A UIScrollView does zoom properly: pinch around the fingers, bounce at the edges, double-tap
/// to zoom in where tapped and back out.
private struct ZoomableImage: UIViewRepresentable {
    let image: UIImage
    @Binding var zoomed: Bool

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.delegate = context.coordinator
        scrollView.maximumZoomScale = 5
        scrollView.minimumZoomScale = 1
        scrollView.bouncesZoom = true
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = true
        imageView.frame = scrollView.bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scrollView.addSubview(imageView)
        context.coordinator.imageView = imageView
        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)
        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        context.coordinator.parent = self
        if context.coordinator.imageView?.image !== image { context.coordinator.imageView?.image = image }
        // Swiped to another page: this one goes back to fit.
        if !zoomed, scrollView.zoomScale != 1 { scrollView.setZoomScale(1, animated: false) }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        var parent: ZoomableImage
        weak var imageView: UIImageView?

        init(parent: ZoomableImage) { self.parent = parent }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            let isZoomed = scrollView.zoomScale > 1.01
            if parent.zoomed != isZoomed { parent.zoomed = isZoomed }
        }

        @objc func doubleTapped(_ recognizer: UITapGestureRecognizer) {
            guard let scrollView = recognizer.view as? UIScrollView, let imageView else { return }
            if scrollView.zoomScale > 1.01 {
                scrollView.setZoomScale(1, animated: true)
            } else {
                let point = recognizer.location(in: imageView)
                let scale: CGFloat = 2.5
                let size = CGSize(width: scrollView.bounds.width / scale, height: scrollView.bounds.height / scale)
                scrollView.zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                                           width: size.width, height: size.height), animated: true)
            }
        }
    }
}
