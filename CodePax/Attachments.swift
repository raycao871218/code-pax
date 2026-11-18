import Foundation
import UIKit
import ImageIO

struct UploadedAttachment: Codable, Identifiable, Sendable {
    let id: String
    let name: String
    let size: Int
    let kind: String
    let path: String
    var uploadPath: String? = nil
    var symbol: String { kind == "image" ? "photo" : "doc" }
    var formattedSize: String { ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file) }
}

enum AttachmentPolicy {
    static let maximumSize = 20 * 1024 * 1024
    static let maximumCount = 8
    static func validate(size: Int, count: Int) throws {
        guard count < maximumCount else { throw ConnectionError.message("每次最多添加 8 个附件。") }
        guard size > 0, size <= maximumSize else { throw ConnectionError.message("附件不能为空，单个附件不能超过 20 MB。") }
    }
    static func displayText(_ text: String, names: [String]) -> String {
        ([text].filter { !$0.isEmpty } + names.map { "📎 " + $0 }).joined(separator: "\n\n")
    }
}

struct RemoteFileInfo: Decodable, Sendable {
    let name: String
    let path: String
    let size: Int
    let sha256: String
}

struct RemoteFileTarget: Identifiable {
    let path: String
    var id: String { path }
}

enum RemoteFileLink {
    static func path(_ url: URL, relativeTo documentPath: String? = nil) -> String? {
        if url.scheme != nil, !["file", "sandbox"].contains(url.scheme?.lowercased() ?? "") {
            let raw = url.absoluteString
            if raw.range(of: "^[^:/]+[.][^:/]+:[0-9]+(?::[0-9]+)?$", options: .regularExpression) != nil {
                return raw.replacingOccurrences(of: ":[0-9]+(?::[0-9]+)?$", with: "", options: .regularExpression)
            }
            return nil
        }
        guard url.host == nil || url.host == "" || url.host == "localhost" else { return nil }
        let path = url.path.replacingOccurrences(of: ":[0-9]+(?::[0-9]+)?$", with: "", options: .regularExpression)
        guard !path.isEmpty else { return nil }
        if !path.hasPrefix("/"), let documentPath {
            let combined = ((documentPath as NSString).deletingLastPathComponent as NSString).appendingPathComponent(path)
            return (combined as NSString).standardizingPath
        }
        return path
    }
}

struct PreparedAttachment {
    let data: Data
    let name: String
}

enum AttachmentImage {
    static func prepare(_ original: Data, name originalName: String) -> PreparedAttachment {
        var data = original
        var name = originalName
        if let source = CGImageSourceCreateWithData(original as CFData, nil), let type = CGImageSourceGetType(source) as String? {
            let base = URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent
            let ext = URL(fileURLWithPath: name).pathExtension.lowercased()
            if type == "public.png", ext != "png" { name = base + ".png" }
            else if type == "public.jpeg", !["jpg", "jpeg"].contains(ext) { name = base + ".jpg" }
            else if !["public.jpeg", "public.png"].contains(type), let image = UIImage(data: original), let jpeg = image.jpegData(compressionQuality: 0.9) {
                data = jpeg; name = base + ".jpg"
            }
        }
        return PreparedAttachment(data: data, name: name)
    }
}
