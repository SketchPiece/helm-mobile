import SwiftUI
import UIKit

/// The composer's text field. A UITextView rather than SwiftUI's TextField because only UIKit
/// lets "Paste" accept images: with a picture on the clipboard the edit menu offers Paste and the
/// images land as attachments instead of being ignored.
struct ComposerTextView: UIViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    var placeholder: String
    var minLines = 1
    var maxLines = 8
    var accessibilityIdentifier: String?
    var onPasteImages: ([UIImage]) -> Void

    func makeUIView(context: Context) -> PastingTextView {
        let view = PastingTextView()
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        // Always scrollable: toggling it as the text crosses the line limit made the field jump.
        // While the text fits, the frame is as tall as the text, so there is nothing to scroll.
        view.isScrollEnabled = true
        view.showsVerticalScrollIndicator = false
        view.adjustsFontForContentSizeCategory = true
        view.font = Self.font
        view.textColor = UIColor(Palette.text)
        view.tintColor = UIColor(Palette.accent)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.placeholderLabel.text = placeholder
        view.placeholderLabel.font = Self.font
        view.placeholderLabel.textColor = UIColor(Palette.placeholder)
        view.accessibilityIdentifier = accessibilityIdentifier
        view.onPasteImages = onPasteImages
        view.text = text
        view.updatePlaceholder()
        return view
    }

    func updateUIView(_ view: PastingTextView, context: Context) {
        context.coordinator.parent = self
        view.onPasteImages = onPasteImages
        if view.text != text {
            view.text = text
            view.updatePlaceholder()
        }
        view.placeholderLabel.text = placeholder
        // Focus follows the binding, on the next turn so it never fights an ongoing update.
        if isFocused != view.isFirstResponder {
            DispatchQueue.main.async {
                if isFocused, !view.isFirstResponder { view.becomeFirstResponder() }
                if !isFocused, view.isFirstResponder { view.resignFirstResponder() }
            }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView view: PastingTextView, context: Context) -> CGSize? {
        let width = proposal.width ?? 300
        let line = view.font?.lineHeight ?? 22
        let fitting = view.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        let height = min(max(fitting, line * CGFloat(minLines)), line * CGFloat(maxLines))
        return CGSize(width: width, height: ceil(height))
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    static var font: UIFont {
        let base = UIFont(name: "IBMPlexSans-Regular", size: 17) ?? .systemFont(ofSize: 17)
        return UIFontMetrics(forTextStyle: .body).scaledFont(for: base)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: ComposerTextView
        init(parent: ComposerTextView) { self.parent = parent }

        func textViewDidChange(_ textView: UITextView) {
            (textView as? PastingTextView)?.updatePlaceholder()
            parent.text = textView.text
            // Keep the caret in view once the text outgrows the field, after the resize lands.
            DispatchQueue.main.async {
                textView.scrollRangeToVisible(textView.selectedRange)
            }
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            if !parent.isFocused { parent.isFocused = true }
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            if parent.isFocused { parent.isFocused = false }
        }
    }
}

final class PastingTextView: UITextView {
    let placeholderLabel = UILabel()
    var onPasteImages: (([UIImage]) -> Void)?

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        placeholderLabel.numberOfLines = 1
        placeholderLabel.adjustsFontForContentSizeCategory = true
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(placeholderLabel)
        NSLayoutConstraint.activate([
            placeholderLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            placeholderLabel.topAnchor.constraint(equalTo: topAnchor),
            placeholderLabel.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func updatePlaceholder() {
        placeholderLabel.isHidden = !text.isEmpty
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)), UIPasteboard.general.hasImages { return true }
        return super.canPerformAction(action, withSender: sender)
    }

    override func paste(_ sender: Any?) {
        let board = UIPasteboard.general
        if board.hasImages, let images = board.images, !images.isEmpty {
            onPasteImages?(images)
            // Text copied together with the picture still goes in.
            if board.hasStrings, let string = board.string, !string.isEmpty {
                insertText(string)
            }
            return
        }
        super.paste(sender)
    }
}
