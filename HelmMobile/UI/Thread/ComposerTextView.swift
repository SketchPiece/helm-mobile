import GameController
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
    /// Settings → Keyboard: Return sends (Shift-Return is a new line) or inserts a new line.
    var returnKey: ReturnKeyBehavior = .newline
    /// Sends the draft. `alternate` is Command-Return while Return sends: the other follow-up.
    var onSubmit: ((_ alternate: Bool) -> Void)?
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
        view.configureReturnKey(returnKey, onSubmit: onSubmit)
        view.text = text
        view.updatePlaceholder()
        return view
    }

    func updateUIView(_ view: PastingTextView, context: Context) {
        context.coordinator.parent = self
        view.onPasteImages = onPasteImages
        view.configureReturnKey(returnKey, onSubmit: onSubmit)
        view.textColor = UIColor(Palette.text)
        view.tintColor = UIColor(Palette.accent)
        view.placeholderLabel.textColor = UIColor(Palette.placeholder)
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

        /// The on-screen keyboard's Return; hardware Return arrives as a key command instead.
        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            guard text == "\n", parent.returnKey == .send, let onSubmit = parent.onSubmit else { return true }
            onSubmit(false)
            return false
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

    private var returnKey = ReturnKeyBehavior.newline
    private var onSubmit: ((Bool) -> Void)?

    func configureReturnKey(_ behavior: ReturnKeyBehavior, onSubmit: ((Bool) -> Void)?) {
        self.onSubmit = onSubmit
        returnKey = behavior
        let type: UIReturnKeyType = behavior == .send && onSubmit != nil ? .send : .default
        guard returnKeyType != type else { return }
        returnKeyType = type
        if isFirstResponder { reloadInputViews() }
    }

    /// Hardware keyboard: Return and Shift-Return per the setting, Command-Return always sends.
    override var keyCommands: [UIKeyCommand]? {
        guard onSubmit != nil else { return super.keyCommands }
        var commands = [
            UIKeyCommand(input: "\r", modifierFlags: .command, action: #selector(commandReturn)),
        ]
        if returnKey == .send {
            commands.append(UIKeyCommand(input: "\r", modifierFlags: [], action: #selector(plainReturn)))
            commands.append(UIKeyCommand(input: "\r", modifierFlags: .shift, action: #selector(newline)))
        }
        commands.forEach { $0.wantsPriorityOverSystemBehavior = true }
        return commands + (super.keyCommands ?? [])
    }

    @objc private func plainReturn() { onSubmit?(false) }

    @objc private func commandReturn() { onSubmit?(returnKey == .send) }

    @objc private func newline() { insertText("\n") }

    private lazy var systemShortcuts = (inputAssistantItem.leadingBarButtonGroups, inputAssistantItem.trailingBarButtonGroups)

    /// With a hardware keyboard the shortcut buttons (undo, paste) widen the bar iPadOS keeps at
    /// the bottom, which then covers the composer; the on-screen keyboard keeps them.
    override func becomeFirstResponder() -> Bool {
        let hardware = GCKeyboard.coalesced != nil
        inputAssistantItem.leadingBarButtonGroups = hardware ? [] : systemShortcuts.0
        inputAssistantItem.trailingBarButtonGroups = hardware ? [] : systemShortcuts.1
        return super.becomeFirstResponder()
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
