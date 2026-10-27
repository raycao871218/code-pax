import SwiftUI

struct FullMessageButton: View {
    @ObservedObject var model: WorkspaceModel
    let sessionID: String
    let messageID: String
    let length: Int
    var plainText = false
    @State private var presented = false

    var body: some View {
        Button { presented = true } label: {
            Label("查看完整内容（\(length) 字符）", systemImage: "doc.text.magnifyingglass")
                .font(.caption)
        }.buttonStyle(.bordered)
            .sheet(isPresented: $presented) {
                FullMessageView(model: model, sessionID: sessionID, messageID: messageID, plainText: plainText)
                    .appAppearance()
            }
    }
}

private struct FullMessageView: View {
    @ObservedObject var model: WorkspaceModel
    let sessionID: String
    let messageID: String
    let plainText: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var revision: String?
    @State private var nextOffset: Int? = 0
    @State private var loaded = 0
    @State private var total = 0
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if plainText {
                        Text(text).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                    } else { RichMarkdown(text: text).equatable() }
                    if let error {
                        Text(error).font(.callout).foregroundStyle(.red)
                        Button("从头重新读取") {
                            text = ""; revision = nil; nextOffset = 0; loaded = 0
                            Task { await loadNext() }
                        }.disabled(loading)
                    }
                    if loading { ProgressView("正在读取完整内容…") }
                    else if nextOffset != nil {
                        Button(error == nil ? "加载下一段" : "重试读取") { Task { await loadNext() } }
                            .buttonStyle(.bordered)
                    }
                }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle(nextOffset == nil ? "完整内容" : "已加载 \(loaded) / \(total) 字符")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(nextOffset == nil ? "复制全文" : "复制已加载内容", systemImage: "doc.on.doc") {
                        UIPasteboard.general.string = text
                    }.disabled(text.isEmpty)
                }
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            }
        }.modifier(RemoteFileLinks(model: model, sessionID: sessionID)).task { await loadNext() }
    }

    private func loadNext() async {
        guard !loading, let offset = nextOffset else { return }
        loading = true; error = nil
        defer { loading = false }
        do {
            let page = try await model.messageBody(sessionID: sessionID, messageID: messageID, offset: offset, revision: revision)
            try Task.checkCancellation()
            text += page.text
            revision = page.revision; nextOffset = page.nextOffset; total = page.contentLength
            loaded = page.nextOffset ?? page.contentLength
        } catch is CancellationError { return }
        catch { self.error = error.localizedDescription }
    }
}
