import SwiftUI
import UIKit
import MarkdownUI

/// Native GFM rendering; messages and plans share the same typography and block support.
struct RichMarkdown: View, Equatable {
    let text: String
    private static let theme = Theme.gitHub
        .text {
            FontSize(16)
            ForegroundColor(.primary)
            BackgroundColor(nil)
        }
        .code {
            FontFamilyVariant(.monospaced)
            FontSize(.em(0.87))
            ForegroundColor(.primary)
            BackgroundColor(Color.primary.opacity(0.08))
        }
        .codeBlock { configuration in
            MarkdownCodeBlock(language: configuration.language, code: configuration.content)
                .markdownMargin(top: 0, bottom: 14)
        }
        .table { configuration in
            ScrollView(.horizontal) {
                configuration.label
                    .fixedSize(horizontal: true, vertical: false)
                    .markdownTableBorderStyle(.init(color: Color.primary.opacity(0.16)))
                    .markdownTableBackgroundStyle(.alternatingRows(.clear, Color.primary.opacity(0.04)))
            }.defaultScrollAnchor(.topLeading).markdownMargin(top: 0, bottom: 14)
        }

    var body: some View {
        Markdown(text)
            .markdownTheme(Self.theme)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MarkdownCodeBlock: View {
    @Environment(\.interfaceTheme) private var theme
    let language: String?
    let code: String
    @State private var copied = false
    private var codeHeight: CGFloat {
        let lines = max(1, code.split(separator: "\n", omittingEmptySubsequences: false).count)
        return min(320, max(52, CGFloat(lines) * (UIFont.preferredFont(forTextStyle: .caption1).lineHeight + 3) + 24))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language?.isEmpty == false ? language! : "代码").font(.caption.monospaced()).foregroundStyle(.secondary)
                Spacer()
                Button {
                    UIPasteboard.general.string = code
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(2)); copied = false }
                } label: {
                    Label(copied ? "已复制" : "复制", systemImage: copied ? "checkmark" : "doc.on.doc")
                }.buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
                    .accessibilityLabel("复制代码")
            }.padding(.horizontal, 14).padding(.vertical, 10)
            Divider()
            GeometryReader { viewport in
                ScrollView([.horizontal, .vertical]) {
                    Text(code).font(.system(.caption, design: .monospaced)).lineSpacing(3)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: true, vertical: true).textSelection(.enabled).padding(12)
                        .frame(minWidth: viewport.size.width, alignment: .leading)
                }.defaultScrollAnchor(.topLeading)
            }.frame(height: codeHeight)
        }.background(theme.input, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(theme.border, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

/// Explicit contrast avoids the system's adaptive primary tint becoming white-on-white.
struct ComposerActionButton: View {
    @Environment(\.interfaceTheme) private var theme
    let state: ComposerState
    let disabled: Bool
    let action: () -> Void
    private var background: Color {
        if disabled && state != .sending { return Color(.tertiarySystemFill) }
        return theme.actionFill
    }
    var body: some View {
        Button(action: action) {
            Group {
                if state == .sending { ProgressView().tint(.white) }
                else { Image(systemName: state == .running ? "stop.fill" : "arrow.up").font(.system(size: 18, weight: .semibold)) }
            }.foregroundStyle(disabled && state != .sending ? Color.secondary : Color.white)
                .frame(width: 44, height: 44)
                .background(background, in: Circle())
                .overlay(Circle().stroke(Color.primary.opacity(disabled ? 0.12 : 0), lineWidth: 1))
                .contentShape(Circle())
        }.buttonStyle(.plain).disabled(disabled)
            .accessibilityLabel(state == .running ? "停止任务" : state == .sending ? "正在发送" : "发送消息")

    }
}
