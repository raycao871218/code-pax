import SwiftUI
import XCTest
import UIKit
import UniformTypeIdentifiers
@testable import CodexIPad

final class InteractionTests: XCTestCase {
    @MainActor
    func testSkinChangesImmediatelyAndPreservesIndependentAppearance() async throws {
        let suite = "skin-test-" + UUID().uuidString
        let store = try XCTUnwrap(UserDefaults(suiteName: suite))
        store.set("dark", forKey: "appearance")
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let observed = ThemeObservation()
        let page = UIHostingController(rootView: ThemeProbe(observed: observed).appAppearance(store: store))
        window.rootViewController = page
        window.makeKeyAndVisible()
        defer { window.isHidden = true; store.removePersistentDomain(forName: suite) }
        for expected in [InterfaceSkin.classic, .companion, .classic] {
            store.set(expected.rawValue, forKey: "interfaceSkin")
            for _ in 0..<30 where observed.skin != expected || observed.scheme != .dark {
                try await Task.sleep(for: .milliseconds(50))
            }
            XCTAssertEqual(observed.skin, expected)
            XCTAssertEqual(observed.scheme, .dark)
            XCTAssertTrue(window.rootViewController === page)
        }
        for palette in InterfacePalette.allCases {
            store.set(palette.rawValue, forKey: "interfacePalette")
            for _ in 0..<30 where observed.palette != palette { try await Task.sleep(for: .milliseconds(50)) }
            XCTAssertEqual(observed.palette, palette)
            XCTAssertEqual(observed.skin, .classic)
            XCTAssertTrue(window.rootViewController === page)
        }
        store.set("light", forKey: "appearance")
        for _ in 0..<30 where observed.scheme != .light { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertEqual(observed.skin, .classic)
        XCTAssertEqual(observed.scheme, .light)
    }

    @MainActor
    func testSendButtonWhiteGlyphHasReadableContrastInBothSkinsAndModes() {
        for skin in InterfaceSkin.allCases {
            for scheme in [ColorScheme.light, .dark] {
                for palette in InterfacePalette.allCases {
                let color = UIColor(InterfaceTheme(skin: skin, colorScheme: scheme, palette: palette).actionFill)
                var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                XCTAssertTrue(color.getRed(&r, green: &g, blue: &b, alpha: &a))
                func linear(_ c: CGFloat) -> Double {
                    let v = Double(c)
                    return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
                }
                let luminance = 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
                XCTAssertGreaterThanOrEqual(1.05 / (luminance + 0.05), 4.5, palette.title)
                }
            }
        }
    }

    func testCompanionPresenceFollowsCurrentTurnAndTerminalStates() {
        let oldCommand = CodexMessage(id: "old", kind: "commandExecution", text: "old", status: "inProgress")
        let user = CodexMessage(id: "user", kind: "userMessage", text: "new task", status: "accepted")
        let command = CodexMessage(id: "cmd", kind: "commandExecution", text: "swift test", status: "inProgress")
        let reply = CodexMessage(id: "reply", kind: "agentMessage", text: "Working", status: "inProgress")
        func resolve(_ status: String, _ messages: [CodexMessage]) -> CompanionState {
            CompanionState.resolve(connected: true, status: status, messages: messages)
        }
        XCTAssertEqual(resolve("inProgress", [oldCommand, user]), .thinking)
        XCTAssertEqual(resolve("inProgress", [user, command]), .executing)
        XCTAssertEqual(resolve("inProgress", [user, command, reply]), .replying)
        for (status, expected) in [("completed", CompanionState.completed), ("failed", .failed),
                                   ("interrupted", .interrupted), ("waiting", .waiting), ("unknown", .idle)] {
            let state = resolve(status, [user, command])
            XCTAssertEqual(state, expected)
            XCTAssertFalse(state.animates)
        }
    }

    func testCompanionPresenceNeverImpliesWorkWhenDisconnectedOrAwaitingReceipt() {
        XCTAssertEqual(CompanionState.resolve(connected: false, status: "inProgress", messages: [], sending: true), .offline)
        XCTAssertEqual(CompanionState.resolve(connected: true, status: "completed", messages: [], sending: true), .sending)
        XCTAssertEqual(CompanionState.resolve(connected: true, status: "completed", messages: [], uncertain: true), .uncertain)
        XCTAssertEqual(CompanionState.resolve(connected: true, status: "inProgress", messages: [], hasApprovals: true), .waiting)
        XCTAssertEqual(CompanionState.resolve(connected: true, status: nil, messages: []), .idle)
    }

    func testThinkingAnimationUsesDrawnFramesAndStopsForReducedMotion() {
        XCTAssertEqual(ThinkingFrames.index(elapsed: 0, enabled: true), 0)
        XCTAssertEqual(ThinkingFrames.index(elapsed: 0.66, enabled: true), 1)
        XCTAssertEqual(ThinkingFrames.index(elapsed: 1.36, enabled: true), 2)
        XCTAssertEqual(ThinkingFrames.index(elapsed: 1.52, enabled: true), 3)
        XCTAssertEqual(ThinkingFrames.index(elapsed: ThinkingFrames.cycle + 0.66, enabled: true), 1)
        for time in [0.0, 0.66, 1.36, 1.52, Double.infinity, -1] {
            XCTAssertEqual(ThinkingFrames.index(elapsed: time, enabled: false), 0)
        }
        let images = (0..<4).compactMap { UIImage(named: "CodePaxThinking\($0)", in: Bundle(for: WorkspaceModel.self), compatibleWith: nil) }
        XCTAssertEqual(images.count, 4)
        XCTAssertEqual(Set(images.compactMap { $0.pngData() }).count, 4, "Each pose must be a different actual bitmap")
    }

    func testOnlyNewestCurrentTurnReplyGetsAnimationWithoutASeparateStatusCard() {
        let old = CodexMessage(id: "old", kind: "agentMessage", text: "previous", status: "completed")
        let user = CodexMessage(id: "user", kind: "userMessage", text: "task", status: "accepted")
        let first = CodexMessage(id: "first", kind: "agentMessage", text: "checking", status: "completed")
        let last = CodexMessage(id: "last", kind: "agentMessage", text: "answer", status: "inProgress")
        XCTAssertNil(CompanionReplyPolicy.latestReplyID(in: [old, user]))
        let pending = CompanionReplyPolicy.displayedMessages([old, user], state: .thinking)
        XCTAssertEqual(pending.count, 3)
        XCTAssertEqual(pending.last?.kind, "agentMessage")
        XCTAssertEqual(pending.last?.text, "")
        XCTAssertEqual(CompanionReplyPolicy.latestReplyID(in: pending), pending.last?.id)
        XCTAssertEqual(CompanionReplyPolicy.latestReplyID(in: [old, user, first, last]), "last")
        XCTAssertEqual(CompanionReplyPolicy.displayedMessages([old, user, first, last], state: .thinking).count, 4)
        for state in [CompanionState.offline, .completed, .failed, .waiting] {
            XCTAssertEqual(CompanionReplyPolicy.displayedMessages([old, user], state: state).count, 2)
        }
    }

    func testMarkdownFileReaderPreservesUTF8AndUTF16AndOffersSafeFallbacks() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("说明.MD")
        let source = "# 标题\n\n**中文内容**\n\n| A | B |\n|---|---|\n| 1 | 2 |"
        for encoding in [String.Encoding.utf8, .utf16] {
            try source.write(to: file, atomically: true, encoding: encoding)
            XCTAssertEqual(try MarkdownFileContent.read(file).text, source)
        }
        try ("\u{FEFF}" + source).write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(try MarkdownFileContent.read(file).text, source)
        try Data([0xFF, 0x00, 0xFE]).write(to: file)
        XCTAssertTrue(try MarkdownFileContent.read(file).text == nil)
        XCTAssertNotNil(try MarkdownFileContent.read(file).notice)
        try Data(repeating: 65, count: MarkdownFileContent.maximumSize + 1).write(to: file)
        XCTAssertTrue(try MarkdownFileContent.read(file).text == nil)
        XCTAssertNotNil(try MarkdownFileContent.read(file).notice)
        let pdf = directory.appendingPathComponent("report.pdf")
        XCTAssertFalse(MarkdownFileContent.supports(pdf))
        XCTAssertNil(try MarkdownFileContent.read(pdf).notice)
        for name in ["a.md", "a.MARKDOWN", "a.mdown", "a.mkd"] {
            XCTAssertTrue(MarkdownFileContent.supports(directory.appendingPathComponent(name)))
        }
    }

    func testLinksInsideMarkdownResolveAgainstTheRemoteDocumentDirectory() throws {
        let relative = try XCTUnwrap(URL(string: "../images/result.png"))
        XCTAssertEqual(RemoteFileLink.path(relative, relativeTo: "/project/docs/readme.md"), "/project/images/result.png")
        XCTAssertEqual(RemoteFileLink.path(try XCTUnwrap(URL(string: "guide.md")), relativeTo: "docs/readme.md"), "docs/guide.md")
        XCTAssertEqual(RemoteFileLink.path(try XCTUnwrap(URL(string: "file:///project/other.md")), relativeTo: "/project/docs/readme.md"), "/project/other.md")
        XCTAssertNil(RemoteFileLink.path(try XCTUnwrap(URL(string: "https://example.com/readme.md")), relativeTo: "/project/docs/readme.md"))
    }

    func testRemoteFileLinksRouteOnlyProjectFileURLsAndKeepOrdinaryLinksExternal() throws {
        XCTAssertEqual(RemoteFileLink.path(try XCTUnwrap(URL(string: "file:///home/me/result%20one.pdf#L12"))), "/home/me/result one.pdf")
        XCTAssertEqual(RemoteFileLink.path(try XCTUnwrap(URL(string: "sources/main.swift:12:3"))), "sources/main.swift")
        XCTAssertEqual(RemoteFileLink.path(try XCTUnwrap(URL(string: "sandbox:/home/me/chart.png"))), "/home/me/chart.png")
        XCTAssertEqual(RemoteFileLink.path(try XCTUnwrap(URL(string: "docs/a%2520b.txt"))), "docs/a%20b.txt")
        XCTAssertEqual(RemoteFileLink.path(try XCTUnwrap(URL(string: "main.swift:12"))), "main.swift")
        XCTAssertNil(RemoteFileLink.path(try XCTUnwrap(URL(string: "https://example.com/report.pdf"))))
        XCTAssertNil(RemoteFileLink.path(try XCTUnwrap(URL(string: "file://other-host/private.txt"))))
        XCTAssertNil(RemoteFileLink.path(try XCTUnwrap(URL(string: "tel:123456789"))))
    }

    func testPinnedChatsSortFirstAndArchiveIsHiddenWithoutLosingSummary() throws {
        let json = """
        [{"id":"new","title":"New","cwd":"/p","status":"completed","updatedAt":10},
         {"id":"pin","title":"Pinned","cwd":"/p","status":"completed","updatedAt":1,"pinned":true},
         {"id":"old","title":"Old","cwd":"/p","status":"completed","updatedAt":0},
         {"id":"hidden","title":"Archive","cwd":"/p","status":"completed","updatedAt":20,"archived":true}]
        """
        let sessions = try JSONDecoder().decode([CodexSessionSummary].self, from: Data(json.utf8))
        XCTAssertEqual(SessionListPolicy.visible(sessions).map(\.id), ["pin", "new", "old"])
        XCTAssertEqual(sessions.filter { $0.archived == true }.first?.title, "Archive")
    }

    func testAttachmentCardsDoNotRepeatNamesInsideTheBubble() {
        let attachment = UploadedAttachment(id: "a", name: "需求.pdf", size: 12, kind: "file", path: "/p/a.pdf")
        XCTAssertEqual(CodexMessage(id: "1", kind: "userMessage", text: "请检查\n\n📎 需求.pdf", status: "accepted", attachments: [attachment]).userMessageText, "请检查")
        XCTAssertEqual(CodexMessage(id: "2", kind: "userMessage", text: "📎 需求.pdf", status: "accepted", attachments: [attachment]).userMessageText, "")
        XCTAssertEqual(CodexMessage(id: "3", kind: "userMessage", text: "📎 需求.pdf", status: "accepted").userMessageText, "📎 需求.pdf")
    }

    @MainActor
    func testPastedImagesBecomeAttachmentsAndCannotLeakObjectCharactersIntoDraft() throws {
        let editor = ComposerTextView()
        editor.text = "草稿"
        let image = try XCTUnwrap(UIImage(systemName: "photo"))
        let provider = NSItemProvider(object: image)
        XCTAssertTrue(AttachmentImport.isAttachment(provider))
        var received = 0
        editor.receiveAttachments = { received += $0.count }
        editor.canAttach = true
        editor.paste(itemProviders: [provider])
        XCTAssertEqual(received, 1)
        XCTAssertEqual(editor.text, "草稿")
        editor.canAttach = false
        editor.paste(itemProviders: [provider])
        XCTAssertEqual(received, 1)
        XCTAssertEqual(editor.text, "草稿")
    }

    @MainActor
    func testUIImageClipboardProviderProducesAReadableImageFile() async throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
        let url = try await AttachmentImport.copy(NSItemProvider(object: image))
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let imported = try Data(contentsOf: url)
        XCTAssertNotNil(UIImage(data: imported))
        let prepared = AttachmentImage.prepare(imported, name: url.lastPathComponent)
        XCTAssertNotNil(UIImage(data: prepared.data))
        XCTAssertTrue(["png", "jpg", "jpeg"].contains(URL(fileURLWithPath: prepared.name).pathExtension.lowercased()))
        let png = try XCTUnwrap(image.pngData())
        XCTAssertTrue(AttachmentImage.prepare(png, name: "clipboard").name.hasSuffix(".png"))
        let document = Data("plain document".utf8)
        XCTAssertEqual(AttachmentImage.prepare(document, name: "notes.txt").data, document)
        XCTAssertEqual(AttachmentImage.prepare(document, name: "notes.txt").name, "notes.txt")
    }

    func testProviderFileIsCopiedBeforeItsTemporaryRepresentationExpires() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("original.png")
        let data = Data("image-representation".utf8)
        try data.write(to: source)
        let provider = NSItemProvider()
        provider.suggestedName = "截图"
        provider.registerFileRepresentation(forTypeIdentifier: UTType.png.identifier, fileOptions: [], visibility: .all) { completion in
            completion(source, false, nil)
            return nil
        }
        let copy = try await AttachmentImport.copy(provider)
        defer { try? FileManager.default.removeItem(at: copy.deletingLastPathComponent()) }
        try FileManager.default.removeItem(at: source)
        XCTAssertEqual(try Data(contentsOf: copy), data)
        XCTAssertEqual(copy.lastPathComponent, "截图.png")
    }
}

private final class ThemeObservation {
    var skin: InterfaceSkin?
    var scheme: ColorScheme?
    var palette: InterfacePalette?
}
private struct ThemeProbe: UIViewRepresentable {
    @Environment(\.interfaceTheme) private var theme
    let observed: ThemeObservation
    func makeUIView(context: Context) -> UIView { UIView() }
    func updateUIView(_ view: UIView, context: Context) {
        observed.skin = theme.skin
        observed.scheme = theme.colorScheme
        observed.palette = theme.palette
    }
}
