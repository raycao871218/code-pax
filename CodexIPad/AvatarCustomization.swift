import SwiftUI
import UIKit
import ImageIO
import PhotosUI
import UniformTypeIdentifiers

struct AvatarAnimation {
    let frames: [UIImage]
    let durations: [Double]
}
struct AvatarAppearance: @unchecked Sendable {
    var portrait: UIImage?
    var animation: AvatarAnimation?
    var displayPortrait: UIImage? { portrait ?? animation?.frames.first }
    var isCustom: Bool { displayPortrait != nil }
}
enum AvatarImportKind { case portrait, animation }
struct DecodedAvatar: @unchecked Sendable {
    let frames: [UIImage]
    let durations: [Double]
}

enum AvatarMedia {
    static let maximumBytes = 16 * 1024 * 1024
    static let maximumFrames = 48
    static func read(_ url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        guard data.count <= maximumBytes else { throw ConnectionError.message("图片不能超过 16 MB。") }
        return data
    }
    static func decode(_ data: Data, kind: AvatarImportKind) throws -> DecodedAvatar {
        guard !data.isEmpty, data.count <= maximumBytes,
              let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw ConnectionError.message("无法读取图片，请选择 PNG、JPEG、GIF 或 APNG。")
        }
        let count = CGImageSourceGetCount(source)
        guard count > 0, kind == .portrait || count <= maximumFrames else {
            throw ConnectionError.message("动图最多支持 48 帧，请先精简帧数。")
        }
        func thumbnail(_ index: Int, size: Int) throws -> CGImage {
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, index, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: size,
                kCGImageSourceShouldCacheImmediately: true
            ] as CFDictionary) else { throw ConnectionError.message("图片帧无法解码。") }
            return image
        }
        if kind == .portrait { return DecodedAvatar(frames: [UIImage(cgImage: try thumbnail(0, size: 512))], durations: []) }
        if count > 1 {
            var images: [UIImage] = [], durations: [Double] = []
            for index in 0..<count {
                images.append(UIImage(cgImage: try thumbnail(index, size: 384)))
                let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [String: Any] ?? [:]
                let gif = props[kCGImagePropertyGIFDictionary as String] as? [String: Any] ?? [:]
                let png = props[kCGImagePropertyPNGDictionary as String] as? [String: Any] ?? [:]
                let delay = (gif[kCGImagePropertyGIFUnclampedDelayTime as String] as? NSNumber)?.doubleValue
                    ?? (gif[kCGImagePropertyGIFDelayTime as String] as? NSNumber)?.doubleValue
                    ?? (png[kCGImagePropertyAPNGUnclampedDelayTime as String] as? NSNumber)?.doubleValue
                    ?? (png[kCGImagePropertyAPNGDelayTime as String] as? NSNumber)?.doubleValue ?? 0.15
                durations.append(delay.isFinite ? min(3, max(0.06, delay)) : 0.15)
            }
            return DecodedAvatar(frames: images, durations: durations)
        }
        let image = try thumbnail(0, size: 768)
        guard image.width == image.height, image.width >= 128, image.width % 2 == 0 else {
            throw ConnectionError.message("四帧图需为正方形 2×2 排列，边长至少 128 像素且为偶数。也可以直接导入 GIF / APNG。")
        }
        let side = image.width / 2
        let frames = try (0..<4).map { index -> UIImage in
            guard let frame = image.cropping(to: CGRect(x: (index % 2) * side, y: (index / 2) * side, width: side, height: side)) else {
                throw ConnectionError.message("无法拆分四帧图。")
            }
            return UIImage(cgImage: frame)
        }
        return DecodedAvatar(frames: frames, durations: [0.5, 0.55, 0.16, 0.5])
    }
}

/// A bounded loop shared by custom GIF/APNG, sprite sheets, and the bundled animation.
enum AvatarFrameTiming {
    static func index(elapsed: Double, durations: [Double], enabled: Bool) -> Int {
        guard enabled, elapsed.isFinite, elapsed >= 0, !durations.isEmpty,
              durations.allSatisfy({ $0.isFinite && $0 > 0 }) else { return 0 }
        let total = durations.reduce(0, +)
        guard total.isFinite, total > 0 else { return 0 }
        var position = elapsed.truncatingRemainder(dividingBy: total)
        for (index, duration) in durations.enumerated() {
            if position < duration { return index }
            position -= duration
        }
        return 0
    }
}

@MainActor
final class CustomAvatarStore: ObservableObject {
    static let shared = CustomAvatarStore()
    @Published private(set) var appearance = AvatarAppearance()
    @Published private(set) var isImporting = false
    @Published var error: String?
    private let directory: URL
    private struct Manifest: Codable { let folder: String; let portrait: Bool; let durations: [Double] }
    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("CodePaxAppearance", isDirectory: true)
        restoreSaved()
    }
    private func restoreSaved() {
        do {
            let data = try Data(contentsOf: directory.appendingPathComponent("current.json"))
            let manifest = try JSONDecoder().decode(Manifest.self, from: data)
            guard UUID(uuidString: manifest.folder) != nil, manifest.durations.count <= AvatarMedia.maximumFrames,
                  manifest.durations.allSatisfy({ $0.isFinite && $0 >= 0.06 && $0 <= 3 }) else { return }
            let folder = directory.appendingPathComponent(manifest.folder)
            let portrait = manifest.portrait ? UIImage(contentsOfFile: folder.appendingPathComponent("portrait.png").path) : nil
            let frames = manifest.durations.indices.compactMap { UIImage(contentsOfFile: folder.appendingPathComponent("frame-\($0).png").path) }
            let animation = !frames.isEmpty && frames.count == manifest.durations.count ? AvatarAnimation(frames: frames, durations: manifest.durations) : nil
            appearance = AvatarAppearance(portrait: portrait, animation: animation)
        } catch { /* No custom assets yet, or incomplete files: keep the bundled artwork. */ }
    }
    func importFile(_ url: URL, kind: AvatarImportKind) async {
        guard !isImporting else { return }
        isImporting = true; error = nil
        defer { isImporting = false }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do {
            let decoded = try await Task.detached(priority: .userInitiated) { try AvatarMedia.decode(AvatarMedia.read(url), kind: kind) }.value
            try Task.checkCancellation()
            try await apply(decoded, kind: kind)
        } catch { self.error = error.localizedDescription }
    }
    func importData(_ data: Data, kind: AvatarImportKind) async {
        guard !isImporting else { return }
        isImporting = true; error = nil
        defer { isImporting = false }
        do {
            let decoded = try await Task.detached(priority: .userInitiated) { try AvatarMedia.decode(data, kind: kind) }.value
            try Task.checkCancellation()
            try await apply(decoded, kind: kind)
        } catch { self.error = error.localizedDescription }
    }
    private func apply(_ decoded: DecodedAvatar, kind: AvatarImportKind) async throws {
        var updated = appearance
        if kind == .portrait { updated.portrait = decoded.frames.first }
        else { updated.animation = AvatarAnimation(frames: decoded.frames, durations: decoded.durations) }
        let snapshot = updated, location = directory
        try await Task.detached(priority: .userInitiated) { try Self.persist(snapshot, at: location) }.value
        appearance = updated
    }
    func reset() async {
        guard !isImporting else { return }
        isImporting = true
        defer { isImporting = false }
        do {
            let location = directory
            try await Task.detached(priority: .userInitiated) { try Self.persist(AvatarAppearance(), at: location) }.value
            appearance = AvatarAppearance(); error = nil
        } catch { self.error = error.localizedDescription }
    }
    nonisolated private static func persist(_ updated: AvatarAppearance, at directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let folder = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        var committed = false
        defer { if !committed { try? FileManager.default.removeItem(at: folder) } }
        func write(_ image: UIImage, _ name: String) throws {
            guard let png = image.pngData() else { throw ConnectionError.message("无法保存图片，请重试。") }
            try png.write(to: folder.appendingPathComponent(name), options: .atomic)
        }
        if let portrait = updated.portrait { try write(portrait, "portrait.png") }
        if let animation = updated.animation {
            for (index, image) in animation.frames.enumerated() { try write(image, "frame-\(index).png") }
        }
        let manifest = Manifest(folder: folder.lastPathComponent, portrait: updated.portrait != nil, durations: updated.animation?.durations ?? [])
        try JSONEncoder().encode(manifest).write(to: directory.appendingPathComponent("current.json"), options: .atomic)
        committed = true
        // Only remove obsolete asset folders after the new selection is durably committed.
        for url in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] {
            if url != folder, UUID(uuidString: url.lastPathComponent) != nil { try? FileManager.default.removeItem(at: url) }
        }
    }
}

struct AppearanceCustomizationView: View {
    @Environment(\.interfaceTheme) private var theme
    @ObservedObject private var store = CustomAvatarStore.shared
    @AppStorage("avatarAnimationSpeed") private var speed = 1.0
    @State private var showFiles = false
    @State private var kind = AvatarImportKind.portrait
    @State private var photo: PhotosPickerItem?
    @State private var photoLoading = false
    var body: some View {
        Form {
            Section("界面") {
                SkinPicker(); PalettePicker(); AppearancePicker()
                Text("角色主题会同步调整背景和气泡；经典工作台调整强调色。切换后立即生效。").font(.caption).foregroundStyle(.secondary)
            }
            Section("头像与动作") {
                HStack(spacing: 24) {
                    VStack(spacing: 8) { BrandMark().frame(width: 80, height: 80); Text("静态头像").font(.caption) }
                    VStack(spacing: 8) { CompanionAvatar(state: .thinking).frame(width: 80, height: 80); Text("动作预览").font(.caption) }
                    Spacer()
                }.padding(.vertical, 8)
                PhotosPicker(selection: $photo, matching: .images) { Label("从照片选择头像", systemImage: "photo") }
                Button("从文件导入头像", systemImage: "person.crop.square") { kind = .portrait; showFiles = true }
                Button("导入动图 / 四帧图", systemImage: "film.stack") { kind = .animation; showFiles = true }
                if let animation = store.appearance.animation {
                    Text("已导入 \(animation.frames.count) 帧动作").font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Text("播放速度")
                    Slider(value: $speed, in: 0.5...2, step: 0.25)
                    Text(String(format: "%.2g×", speed)).monospacedDigit().frame(width: 42)
                }
                Text("自定义内容保存在本机，不更换桌面图标。聊天头像需选择“角色主题”。只导入头像时保持静态；只导入动作时用第一帧作为头像。动作仍只出现在最新回复，左上角不显示 Logo。").font(.caption).foregroundStyle(.secondary)
                if store.isImporting || photoLoading { ProgressView("正在导入…") }
                if let error = store.error { Text(error).font(.caption).foregroundStyle(.red) }
            }.disabled(store.isImporting || photoLoading)
            Section {
                NavigationLink { AvatarCreationGuide() } label: { Label("制作引导与提示词模板", systemImage: "wand.and.stars") }
                Button("恢复默认头像和动作", role: .destructive) { Task { await store.reset(); speed = 1 } }
                    .disabled(!store.appearance.isCustom || store.isImporting || photoLoading)
            }
        }.scrollContentBackground(theme.isCompanion ? .hidden : .visible)
            .background(theme.canvas)
            .navigationTitle("配色与角色").navigationBarTitleDisplayMode(.inline)
            .fileImporter(isPresented: $showFiles, allowedContentTypes: [.image]) { result in
                switch result {
                case .success(let url): let selectedKind = kind; Task { await store.importFile(url, kind: selectedKind) }
                case .failure(let error): store.error = error.localizedDescription
                }
            }
            .onChange(of: photo) { _, item in
                guard let item else { return }
                photo = nil; photoLoading = true
                Task {
                    defer { photoLoading = false }
                    do {
                        guard let data = try await item.loadTransferable(type: Data.self) else { throw ConnectionError.message("无法读取照片。") }
                        await store.importData(data, kind: .portrait)
                    } catch { store.error = error.localizedDescription }
                }
            }
    }
}

struct AvatarCreationGuide: View {
    static let portraitPrompt = """
    请根据我上传的参考图制作一个应用内角色头像。
    角色描述：[填写外貌、服饰、耳麦等特征]
    画风：[填写喜欢的画风]
    背景：[纯色或透明背景]
    输出一张 1:1 正方形图片，建议 1024×1024。脸部和上半身清晰，主体居中，头部占画面约 75%，保留头饰与耳麦的完整轮廓，四周留少量安全边距。小尺寸下也能辨认表情。保持参考角色身份，不添加文字、水印、边框或光效。
    """
    static let animationPrompt = """
    请以我上传的头像为唯一角色参考，制作一张用于循环思考动画的四帧动作图。
    输出一张 1:1 正方形图片，建议 1536×1536，严格按 2 列×2 行排成四个等大的正方形画面。没有外边距、格间距、分隔线、编号或文字。
    保持四帧中角色身份、画风、脸部比例、发色、头饰、服装、耳麦、背景和光照一致，镜头与头部位置、大小固定。
    阅读顺序为左上→右上→左下→右下：
    1. 眼睛睁开，视线略向上，手抬向下巴。
    2. 手指轻轻托住下巴，露出思索表情。
    3. 保持托腮姿势，轻轻闭眼眨眼。
    4. 睁眼，手开始放下，动作自然回到第一帧。
    动作与表情变化应在小头像里清晰可见。不要整体漂浮、旋转、缩放，不加光环、粒子或思考气泡，不改变角色造型。每帧内保留完整头饰与动作手部，背景与头像一致。[替换上面的动作描述也可以制作自己的循环动作。]
    """
    @State private var copied: String?
    var body: some View {
        List {
            Section("1 · 准备头像") {
                Text("选择清晰的正方形图片；也可以复制下面的模板，附上角色参考图交给绘图工具。头像建议 PNG / JPEG，透明背景也可以。")
                prompt(Self.portraitPrompt, title: "复制头像模板")
            }
            Section("2 · 制作动作") {
                Text("直接导入 GIF / APNG，或用下面的模板生成 2×2 四帧图。四帧图会按左上、右上、左下、右下自动拆分，无需自己制作 GIF。建议保持相同背景和固定镜头。")
                prompt(Self.animationPrompt, title: "复制四帧动作模板")
            }
            Section("3 · 导入与预览") {
                Text("回到“配色与角色”，先导入头像，再导入动作；检查动作预览，调整播放速度即可立即使用。单个文件最多 16 MB，动图最多 48 帧。GIF 建议从“文件”导入，避免照片导出成静态图。")
                Text("系统开启“减少动态效果”或应用进入后台时，动作会停止播放。可随时恢复默认。")
            }
        }.navigationTitle("角色制作引导").navigationBarTitleDisplayMode(.inline)
    }
    private func prompt(_ text: String, title: String) -> some View {
        DisclosureGroup("提示词模板") {
            Text(text).font(.callout).textSelection(.enabled)
            Button(copied == title ? "已复制" : title, systemImage: "doc.on.doc") { UIPasteboard.general.string = text; copied = title }
        }
    }
}
