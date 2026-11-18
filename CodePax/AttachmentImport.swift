import Foundation
import UIKit
import UniformTypeIdentifiers
import ImageIO

/// File representations must be copied inside the provider callback: its URL expires on return.
enum AttachmentImport {
    static func isAttachment(_ provider: NSItemProvider) -> Bool {
        provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) ||
        provider.hasItemConformingToTypeIdentifier(UTType.image.identifier)
    }

    static func copy(_ provider: NSItemProvider) async throws -> URL {
        let suggestedName = provider.suggestedName ?? (provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) ? "图片-" + String(UUID().uuidString.prefix(8)) : nil)
        let identifier = provider.registeredTypeIdentifiers.first(where: {
            UTType($0)?.conforms(to: .image) == true
        }) ?? provider.registeredTypeIdentifiers.first(where: { $0 != UTType.fileURL.identifier }) ?? UTType.item.identifier
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            return try await withCheckedThrowingContinuation { continuation in
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { value, error in
                    do {
                        if let error { throw error }
                        let url = (value as? URL) ?? (value as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                        guard let url, url.isFileURL else { throw ConnectionError.message("无法读取拖入的文件。") }
                        continuation.resume(returning: try copyFile(url, suggestedName: suggestedName, extensionHint: nil))
                    } catch { continuation.resume(throwing: error) }
                }
            }
        }
        return try await withCheckedThrowingContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: identifier) { url, error in
                do {
                    if let error { throw error }
                    guard let url else { throw ConnectionError.message("无法读取图片，请从文件或照片中选择。") }
                    continuation.resume(returning: try copyFile(url, suggestedName: suggestedName, extensionHint: UTType(identifier)?.preferredFilenameExtension))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    private static func copyFile(_ url: URL, suggestedName: String?, extensionHint: String?) throws -> URL {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else { throw ConnectionError.message("暂不支持上传文件夹，请选择文件。") }
        try AttachmentPolicy.validate(size: values.fileSize ?? 0, count: 0)
        var name = suggestedName.map { URL(fileURLWithPath: $0).lastPathComponent } ?? url.lastPathComponent
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let type = CGImageSourceGetType(source) as String?, let ext = UTType(type)?.preferredFilenameExtension {
            let current = URL(fileURLWithPath: name).pathExtension.lowercased()
            if current != ext && !(type == "public.jpeg" && ["jpg", "jpeg"].contains(current)) {
                name = URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent + "." + ext
            }
        } else if URL(fileURLWithPath: name).pathExtension.isEmpty, let ext = extensionHint ?? (url.pathExtension.isEmpty ? nil : url.pathExtension) { name += "." + ext }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("codex-import-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent(name)
        do { try FileManager.default.copyItem(at: url, to: target); return target }
        catch { try? FileManager.default.removeItem(at: directory); throw error }
    }
}

extension WorkspaceModel {
    func attachProviders(_ providers: [NSItemProvider]) {
        guard providers.count <= AttachmentPolicy.maximumCount - attachments.count else {
            attachmentFailed("每次最多添加 8 个附件，请减少选择的文件数量。")
            return
        }
        guard canAddAttachments, beginAttachmentImport() else {
            attachmentFailed("请等待当前操作完成，或检查附件数量。")
            return
        }
        let session = selectedID
        let account = connection.profile.credentialAccount
        Task {
            defer { endAttachmentImport() }
            for provider in providers.prefix(AttachmentPolicy.maximumCount) {
                guard selectedID == session, connection.profile.credentialAccount == account else { return }
                do {
                    let url = try await AttachmentImport.copy(provider)
                    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
                    guard selectedID == session, connection.profile.credentialAccount == account else { return }
                    await attachFile(url)
                } catch { attachmentFailed(error.localizedDescription) }
            }
        }
    }
}
