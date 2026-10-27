import SwiftUI
import QuickLook

struct RemoteFilePreview: View {
    @ObservedObject var model: WorkspaceModel
    let sessionID: String
    let path: String
    @Environment(\.dismiss) private var dismiss
    @State private var file: URL?
    @State private var progress = 0.0
    @State private var error: String?
    @State private var loading = false

    var body: some View {
        NavigationStack {
            Group {
                if let file {
                    DownloadedFileContent(url: file)
                        .modifier(RemoteFileLinks(model: model, sessionID: sessionID, relativeTo: path))
                }
                else if loading {
                    VStack(spacing: 14) {
                        ProgressView(value: progress).frame(maxWidth: 280)
                        Text("正在下载 · \(Int(progress * 100))%").font(.callout).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView {
                        Label("无法打开文件", systemImage: "doc.badge.ellipsis")
                    } description: { Text(error ?? "请重试。") } actions: {
                        Button("重新下载") { Task { await load() } }.buttonStyle(.bordered)
                    }
                }
            }
            .navigationTitle(URL(fileURLWithPath: path).lastPathComponent)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if let file { ShareLink(item: file) { Label("保存 / 分享", systemImage: "square.and.arrow.up") } }
                }
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            }
        }.task { await load() }
    }

    private func load() async {
        guard !loading else { return }
        loading = true; error = nil; progress = 0
        defer { loading = false }
        do {
            let result = try await model.downloadFile(sessionID: sessionID, path: path) { progress = $0 }
            try Task.checkCancellation()
            file = result
        } catch is CancellationError { return }
        catch { self.error = error.localizedDescription }
    }
}

/// Decode only bounded text documents, preserving Chinese text and UTF-16 BOM files.
struct MarkdownFileContent: Sendable {
    let text: String?
    let notice: String?
    static let maximumSize = 4 * 1024 * 1024
    static func supports(_ url: URL) -> Bool {
        ["md", "markdown", "mdown", "mkd", "mdx"].contains(url.pathExtension.lowercased())
    }
    static func read(_ url: URL) throws -> Self {
        guard supports(url) else { return Self(text: nil, notice: nil) }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumSize + 1) ?? Data()
        guard data.count <= maximumSize else {
            return Self(text: nil, notice: "Markdown 文件较大，已切换到系统预览。")
        }
        let encoding: String.Encoding = data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) ? .utf16 : .utf8
        guard let text = String(data: data, encoding: encoding) else {
            return Self(text: nil, notice: "无法识别文本编码，已切换到系统预览。")
        }
        return Self(text: text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text, notice: nil)
    }
}

struct DownloadedFileContent: View {
    let url: URL
    @Environment(\.interfaceTheme) private var theme
    @State private var content: MarkdownFileContent?
    @State private var showSource = false
    @State private var readError: String?
    var body: some View {
        VStack(spacing: 0) {
            if let text = content?.text {
                Picker("查看方式", selection: $showSource) {
                    Text("阅读").tag(false)
                    Text("源码").tag(true)
                }.pickerStyle(.segmented).frame(maxWidth: 320).padding(16)
                Divider()
                ScrollView {
                    Group {
                        if showSource {
                            Text(text).font(.system(.callout, design: .monospaced))
                                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        } else { RichMarkdown(text: text).equatable() }
                    }.padding(24).frame(maxWidth: 1000, alignment: .leading).frame(maxWidth: .infinity, alignment: .center)
                }.defaultScrollAnchor(.topLeading)
            } else if let content {
                if let notice = content.notice {
                    Text(notice).font(.caption).foregroundStyle(.secondary).padding(12)
                }
                QuickLookFile(url: url)
            } else if let readError {
                Text(readError).font(.caption).foregroundStyle(.secondary).padding(12)
                QuickLookFile(url: url)
            } else { ProgressView("正在读取文件…").frame(maxWidth: .infinity, maxHeight: .infinity) }
        }.background(theme.canvas)
            .task(id: url) {
                content = nil; readError = nil; showSource = false
                do {
                    let loaded = try await Task.detached(priority: .userInitiated) { try MarkdownFileContent.read(url) }.value
                    try Task.checkCancellation()
                    content = loaded
                } catch is CancellationError { return }
                catch { readError = error.localizedDescription }
            }
    }
}

private struct QuickLookFile: UIViewControllerRepresentable {
    let url: URL
    func makeCoordinator() -> Coordinator { Coordinator(url: url) }
    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }
    func updateUIViewController(_ controller: QLPreviewController, context: Context) {}
    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { url as NSURL }
    }
}

struct AttachmentPreviewButton: View {
    @Environment(\.interfaceTheme) private var theme
    @ObservedObject var model: WorkspaceModel
    let sessionID: String
    let attachment: UploadedAttachment
    @State private var showPreview = false
    var body: some View {
        Button { showPreview = true } label: {
            HStack(spacing: 8) {
                Image(systemName: attachment.symbol).foregroundStyle(theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(attachment.name).font(.caption.weight(.medium)).lineLimit(1)
                    Text(attachment.formattedSize).font(.caption2).foregroundStyle(.secondary)
                }.frame(maxWidth: 160, alignment: .leading)
            }.contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(!model.supportsDownloads)
            .accessibilityLabel("预览附件 \(attachment.name)")
            .sheet(isPresented: $showPreview) {
                RemoteFilePreview(model: model, sessionID: sessionID, path: attachment.path).appAppearance()
            }
    }
}

struct RemoteFileLinks: ViewModifier {
    @ObservedObject var model: WorkspaceModel
    let sessionID: String
    var relativeTo: String? = nil
    @State private var target: RemoteFileTarget?
    func body(content: Content) -> some View {
        content.environment(\.openURL, OpenURLAction { url in
            if let path = RemoteFileLink.path(url, relativeTo: relativeTo) { target = RemoteFileTarget(path: path); return .handled }
            return .systemAction
        }).sheet(item: $target) { target in
            RemoteFilePreview(model: model, sessionID: sessionID, path: target.path).appAppearance()
        }
    }
}

#if DEBUG
extension MarkdownFileContent {
    static let previewURL: URL = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("项目说明.md")
        let sample = """
        # 项目说明

        这份 **Markdown 文件**会直接以阅读格式打开，中文、*强调*和 `inline code` 都能正常显示。

        ## 工作清单
        - [x] 放大最新回复头像
        - [x] 渲染 Markdown 文件
        - [ ] 继续完善项目

        > 点击顶部“源码”可以查看文件原文。

        ### 代码示例
        ```swift
        let message = "你好，Code Pax"
        print(message)
        ```

        | 内容 | 支持情况 |
        | :--- | :---: |
        | 标题、列表、引用 | 已支持 |
        | 代码块、表格、链接 | 已支持 |

        [相关说明](docs/guide.md)
        """
        try? sample.write(to: url, atomically: true, encoding: .utf8)
        return url
    }()
}
#endif
