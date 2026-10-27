import SwiftUI

struct ArchivedChatsView: View {
    @ObservedObject var model: WorkspaceModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                ForEach(model.archivedSessions) { session in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(session.title).lineLimit(2)
                            Text(URL(fileURLWithPath: session.cwd).lastPathComponent).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("恢复") {
                            Task {
                                if await model.updateSession(session.id, archived: false) {
                                    await model.select(session.id); dismiss()
                                }
                            }
                        }.buttonStyle(.bordered).disabled(model.isBusy || !model.isPrepared)
                    }
                }
                if let error = model.error { Text(error).foregroundStyle(.red) }
            }
            .overlay { if model.archivedSessions.isEmpty { ContentUnavailableView("暂无归档聊天", systemImage: "archivebox") } }
            .navigationTitle("已归档聊天").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }
}
