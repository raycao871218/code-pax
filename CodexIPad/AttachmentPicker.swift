import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct AttachmentPickerButton: View {
    @Environment(\.interfaceTheme) private var theme
    @ObservedObject var model: WorkspaceModel
    @State private var showFiles = false
    @State private var showPhotos = false
    @State private var photos: [PhotosPickerItem] = []

    var body: some View {
        Menu {
            Button("从文件选择", systemImage: "folder") { showFiles = true }
            Button("从照片选择", systemImage: "photo.on.rectangle") { showPhotos = true }
        } label: {
            Image(systemName: "plus").font(.title3).frame(width: 36, height: 36)
                .background(theme.isCompanion ? theme.accent.opacity(0.10) : Color.primary.opacity(0.05), in: Circle())
                .contentShape(Rectangle())
        }.tint(theme.isCompanion ? theme.accent : .primary).accessibilityLabel("添加附件")
            .disabled(!model.canAddAttachments)
            .fileImporter(isPresented: $showFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls):
                    let session = model.selectedID
                    Task {
                        for url in urls {
                            guard model.selectedID == session else { break }
                            await model.attachFile(url)
                        }
                    }
                case .failure(let error): model.attachmentFailed(error.localizedDescription)
                }
            }
            .photosPicker(isPresented: $showPhotos, selection: $photos,
                          maxSelectionCount: max(1, AttachmentPolicy.maximumCount - model.attachments.count), matching: .images)
            .onChange(of: photos) { _, items in
                guard !items.isEmpty else { return }
                guard model.beginAttachmentImport() else { photos = []; return }
                photos = []
                let session = model.selectedID
                Task {
                    defer { model.endAttachmentImport() }
                    for (index, item) in items.enumerated() {
                        do {
                            guard model.selectedID == session else { break }
                            guard let data = try await item.loadTransferable(type: Data.self) else {
                                throw ConnectionError.message("无法读取所选照片。")
                            }
                            guard model.selectedID == session else { break }
                            let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? "jpg"
                            await model.attachData(data, name: "照片-\(UUID().uuidString.prefix(8))-\(index + 1).\(ext)")
                        } catch { model.attachmentFailed(error.localizedDescription) }
                    }
                }
            }
    }
}

struct AttachmentTray: View {
    @ObservedObject var model: WorkspaceModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !model.attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(model.attachments) { attachment in
                            HStack(spacing: 8) {
                                if let sessionID = model.selectedID {
                                    AttachmentPreviewButton(model: model, sessionID: sessionID, attachment: attachment)
                                }
                                Button { model.removeAttachment(attachment.id) } label: {
                                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                                }.buttonStyle(.plain).accessibilityLabel("移除附件 \(attachment.name)")
                                    .disabled(model.isPreparingAttachment || model.isSending || model.hasUncertainSend)
                            }.padding(10).background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                        }
                    }
                }
            }
            if model.isImportingAttachment && !model.isUploadingAttachment {
                ProgressView("正在读取附件…").font(.caption)
            }
            if model.isUploadingAttachment {
                VStack(alignment: .leading, spacing: 5) {
                    Text("正在上传 \(model.uploadingAttachmentName) · \(Int(model.attachmentProgress * 100))%")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    ProgressView(value: model.attachmentProgress)
                }
            }
        }
    }
}
