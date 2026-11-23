import XCTest
import SwiftUI
import UIKit
@testable import CodePax

final class LocalizationTests: XCTestCase {
    func testSystemLanguageUsesSupportedPreferenceAndSafeFallback() {
        XCTAssertEqual(AppLanguage.system.locale(preferredLanguages: ["zh-Hant-TW", "en-US"]).identifier, "zh-Hans")
        XCTAssertEqual(AppLanguage.system.locale(preferredLanguages: ["en-GB", "zh-Hans"]).identifier, "en")
        XCTAssertEqual(AppLanguage.system.locale(preferredLanguages: ["fr-FR", "zh-Hans"]).identifier, "zh-Hans")
        XCTAssertEqual(AppLanguage.system.locale(preferredLanguages: ["fr-FR"]).identifier, "en")
        XCTAssertEqual(AppLanguage.english.locale(preferredLanguages: ["zh-Hans"]).identifier, "en")
        XCTAssertEqual(AppLanguage.simplifiedChinese.locale(preferredLanguages: ["en"]).identifier, "zh-Hans")
        XCTAssertEqual(AppLanguage.resolve("invalid"), .system)
    }

    func testCompiledCatalogTranslatesOwnedStringsAndPreservesInterpolatedData() {
        let en = Locale(identifier: "en"), zh = Locale(identifier: "zh-Hans")
        XCTAssertEqual(L10n.text("选择服务器", locale: en), "Choose server")
        XCTAssertEqual(L10n.text("推理强度", locale: en), "Reasoning effort")
        XCTAssertEqual(L10n.text("跟随系统", locale: en), "Follow system")
        XCTAssertEqual(L10n.text("选择服务器", locale: zh), "选择服务器")
        XCTAssertEqual(L10n.text("正在上传 连接.txt · 50%", locale: en), "Uploading 连接.txt · 50%")
        XCTAssertEqual(L10n.text("使用 Claude Code 新建会话", locale: en), "New Claude Code session")
        XCTAssertEqual(L10n.text("echo '连接服务器'", locale: en), "echo '连接服务器'")
    }

    func testActivitySummaryLocalizesCountsWithoutChangingCommands() {
        let command = CodexMessage(id: "cmd", kind: "commandExecution", text: "echo '连接服务器'", status: "completed")
        let entry = ConversationEntry(messages: [command])
        XCTAssertEqual(entry.localizedSummary(locale: Locale(identifier: "en")), "Executed · 1 command")
        XCTAssertEqual(entry.localizedSummary(locale: Locale(identifier: "zh-Hans")), "已执行 · 1 条命令")
        XCTAssertEqual(entry.messages[0].text, "echo '连接服务器'")
    }

    @MainActor
    func testLanguageChangesImmediatelyWithoutRecreatingViewState() async throws {
        let suite = "locale-" + UUID().uuidString
        let store = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { store.removePersistentDomain(forName: suite) }
        store.set("zh-Hans", forKey: "appLanguage")
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let observation = LocaleObservation()
        let page = UIHostingController(rootView: LocaleProbe(observation: observation).appAppearance(store: store))
        window.rootViewController = page
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        var original: UUID?
        for language in ["zh-Hans", "en", "zh-Hans"] {
            store.set(language, forKey: "appLanguage")
            for _ in 0..<40 where observation.locale != language {
                try await Task.sleep(for: .milliseconds(50))
            }
            XCTAssertEqual(observation.locale, language)
            if original == nil { original = observation.stateID }
            XCTAssertEqual(observation.stateID, original)
            XCTAssertTrue(window.rootViewController === page)
        }
    }
}

@MainActor private final class LocaleObservation {
    var locale = ""
    var stateID: UUID?
}
private struct LocaleProbe: View {
    let observation: LocaleObservation
    @Environment(\.locale) private var locale
    @State private var stateID = UUID()
    var body: some View {
        Text("选择服务器").onChange(of: locale.identifier, initial: true) { _, value in
            observation.locale = value
            observation.stateID = stateID
        }
    }
}
