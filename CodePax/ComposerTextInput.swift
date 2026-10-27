import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Native editor handles physical keyboards and the software Return key alike.
struct ComposerTextInput: UIViewRepresentable {
    @Environment(\.interfaceTheme) private var theme
    @Binding var text: String
    var canSubmit: Bool
    var canAttach = false
    var receiveAttachments: ([NSItemProvider]) -> Void = { _ in }
    var onSubmit: () -> Void

    func makeUIView(context: Context) -> ComposerTextView {
        let view = ComposerTextView()
        view.backgroundColor = .clear
        view.textColor = .label
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.returnKeyType = .send
        view.accessibilityLabel = "给 Codex 一个任务"
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateUIView(_ view: ComposerTextView, context: Context) {
        if view.text != text {
            view.changed = { _ in }
            view.unmarkText()
            view.text = text
        }
        view.tintColor = UIColor(theme.accent)
        view.canSubmit = canSubmit
        view.canAttach = canAttach
        view.receiveAttachments = receiveAttachments
        view.submit = onSubmit
        view.changed = { text = $0 }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: ComposerTextView, context: Context) -> CGSize? {
        let width = proposal.width ?? 300
        let size = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: min(190, max(64, size.height)))
    }
}

final class ComposerTextView: UITextView, UITextViewDelegate {
    var canSubmit = false
    var canAttach = false
    var receiveAttachments: ([NSItemProvider]) -> Void = { _ in }
    var submit: () -> Void = {}
    var changed: (String) -> Void = { _ in }
    private var insertingLineBreak = false

    init() {
        super.init(frame: .zero, textContainer: nil)
        delegate = self
        pasteConfiguration = UIPasteConfiguration(acceptableTypeIdentifiers: [UTType.plainText.identifier, UTType.image.identifier, UTType.fileURL.identifier])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func canPaste(_ itemProviders: [NSItemProvider]) -> Bool {
        if itemProviders.contains(where: AttachmentImport.isAttachment) { return canAttach }
        return super.canPaste(itemProviders)
    }

    override func paste(itemProviders: [NSItemProvider]) {
        let attachments = itemProviders.filter(AttachmentImport.isAttachment)
        if !attachments.isEmpty {
            guard canAttach else { return }
            receiveAttachments(attachments)
            let text = itemProviders.filter { !AttachmentImport.isAttachment($0) }
            if !text.isEmpty { super.paste(itemProviders: text) }
        } else { super.paste(itemProviders: itemProviders) }
    }

    override func paste(_ sender: Any?) {
        let providers = UIPasteboard.general.itemProviders
        if providers.contains(where: AttachmentImport.isAttachment) { paste(itemProviders: providers) }
        else { super.paste(sender) }
    }

    override var keyCommands: [UIKeyCommand]? {
        let send = UIKeyCommand(input: "\r", modifierFlags: [], action: #selector(submitFromKeyboard))
        let alternateSend = UIKeyCommand(input: "\r", modifierFlags: .command, action: #selector(submitFromKeyboard))
        let newline = UIKeyCommand(input: "\r", modifierFlags: .shift, action: #selector(insertLineBreak))
        [send, alternateSend, newline].forEach { $0.wantsPriorityOverSystemBehavior = true }
        return [send, alternateSend, newline] + (super.keyCommands ?? [])
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(submitFromKeyboard) || action == #selector(insertLineBreak) {
            return markedTextRange == nil
        }
        return super.canPerformAction(action, withSender: sender)
    }

    @objc func submitFromKeyboard() {
        guard markedTextRange == nil, canSubmit else { return }
        submit()
    }

    @objc func insertLineBreak() {
        guard markedTextRange == nil else { return }
        insertingLineBreak = true
        insertText("\n")
        insertingLineBreak = false
        changed(text)
    }

    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText replacement: String) -> Bool {
        guard replacement == "\n", !insertingLineBreak, markedTextRange == nil else { return true }
        submitFromKeyboard()
        return false
    }

    func textViewDidChange(_ textView: UITextView) { changed(textView.text) }
}
