import XCTest
import UIKit
@testable import CodexIPad

final class WorkspaceReliabilityTests: XCTestCase {
    func testDraftsAreIsolatedByServerAndSessionAndSurviveRecreation() throws {
        let suite = "draft-test-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = DraftStore(defaults: defaults)
        let a = DraftAddress(server: "server-a", session: "chat-1")
        let b = DraftAddress(server: "server-a", session: "chat-2")
        let c = DraftAddress(server: "server-b", session: "chat-1")
        let first = DraftRecord(text: "第一段\n还没写完")
        store.save(first, at: a)
        store.save(DraftRecord(text: "另一个会话"), at: b)
        XCTAssertEqual(DraftStore(defaults: defaults).load(a).text, first.text)
        XCTAssertEqual(store.load(a).revision, first.revision)
        XCTAssertEqual(store.load(b).text, "另一个会话")
        XCTAssertEqual(store.load(c).text, "")
        let newer = DraftRecord(text: first.text)
        store.save(newer, at: a)
        XCTAssertNotEqual(store.load(a).revision, first.revision)
        store.save(DraftRecord(), at: a)
        XCTAssertEqual(store.load(a).text, "")
        XCTAssertEqual(store.load(b).text, "另一个会话")
    }

    @MainActor
    func testWorkspaceDraftSwitchingAndLateAcknowledgementNeverClearNewTyping() async throws {
        let suite = "workspace-draft-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let connection = ConnectionModel()
        let originalProfile = connection.profile
        connection.profile.host = "draft-test-" + UUID().uuidString + ".invalid"
        let serverA = "workspace.\(connection.profile.endpoint).\(connection.profile.username)"
        let model = WorkspaceModel(connection: connection, defaults: defaults)
        model.connectionChanged()
        await model.select("first")
        model.draft = "相同文字"
        let store = DraftStore(defaults: defaults)
        let revision = store.load(DraftAddress(server: serverA, session: "first")).revision
        let sent: [String: JSONValue] = ["sessionId": .string("first"), "draftRevision": .string(revision)]
        model.clearSubmittedDraft(sent)
        XCTAssertEqual(model.draft, "")
        model.draft = "相同文字"
        model.clearSubmittedDraft(sent) // A late receipt for identical text must not consume a new draft.
        XCTAssertEqual(model.draft, "相同文字")
        await model.select("second")
        XCTAssertEqual(model.draft, "")
        model.draft = "第二个草稿"
        model.clearSubmittedDraft(sent)
        XCTAssertEqual(model.draft, "第二个草稿")
        await model.select("first")
        XCTAssertEqual(model.draft, "相同文字")
        connection.profile.host += "-other"
        let serverB = "workspace.\(connection.profile.endpoint).\(connection.profile.username)"
        model.connectionChanged()
        await model.select("first")
        XCTAssertEqual(model.draft, "")
        connection.profile.host = String(connection.profile.host.dropLast(6))
        model.connectionChanged()
        await model.select("second")
        XCTAssertEqual(model.draft, "第二个草稿")
        let restored = WorkspaceModel(connection: connection, defaults: defaults)
        restored.connectionChanged()
        await restored.select("first")
        XCTAssertEqual(restored.draft, "相同文字")
        UserDefaults.standard.removeObject(forKey: serverA + ".selection")
        UserDefaults.standard.removeObject(forKey: serverB + ".selection")
        connection.profile = originalProfile
    }

    func testReconnectBackoffIsBoundedAndNetworkRecoveryCanRetryImmediately() {
        let start = Date(timeIntervalSince1970: 100)
        var schedule = ReconnectSchedule()
        XCTAssertTrue(schedule.isDue(at: start))
        for delay in [2.0, 4, 8, 16, 30, 30] {
            schedule.failed(at: start)
            XCTAssertFalse(schedule.isDue(at: start.addingTimeInterval(delay - 0.1)))
            XCTAssertTrue(schedule.isDue(at: start.addingTimeInterval(delay)))
        }
        schedule.retryNow()
        XCTAssertTrue(schedule.isDue(at: start))
        schedule.reset()
        XCTAssertEqual(schedule.failures, 0)
    }

    @MainActor
    func testReturnSubmitsOnceAndShiftReturnInsertsNewline() {
        let editor = ComposerTextView()
        editor.text = "发送内容"
        editor.canSubmit = true
        var submissions = 0
        var observed = ""
        editor.submit = { submissions += 1 }
        editor.changed = { observed = $0 }
        XCTAssertFalse(editor.textView(editor, shouldChangeTextIn: NSRange(location: 4, length: 0), replacementText: "\n"))
        XCTAssertEqual(submissions, 1)
        XCTAssertEqual(editor.text, "发送内容")
        editor.selectedRange = NSRange(location: editor.text.utf16.count, length: 0)
        editor.insertLineBreak()
        XCTAssertEqual(submissions, 1)
        XCTAssertEqual(observed, "发送内容\n")
        editor.canSubmit = false
        editor.submitFromKeyboard()
        XCTAssertEqual(submissions, 1)
        XCTAssertTrue(editor.textView(editor, shouldChangeTextIn: NSRange(location: 0, length: 0), replacementText: "粘贴\n多行"))
    }

    @MainActor
    func testChineseCompositionDoesNotSubmitOnReturn() {
        let editor = ComposerTextView()
        let window = UIWindow(frame: UIScreen.main.bounds)
        let controller = UIViewController()
        window.rootViewController = controller
        controller.view.addSubview(editor)
        editor.frame = CGRect(x: 0, y: 0, width: 300, height: 120)
        window.makeKeyAndVisible()
        editor.becomeFirstResponder()
        defer { editor.resignFirstResponder(); window.isHidden = true }
        editor.canSubmit = true
        var submissions = 0
        editor.submit = { submissions += 1 }
        editor.setMarkedText("拼音", selectedRange: NSRange(location: 2, length: 0))
        XCTAssertNotNil(editor.markedTextRange)
        editor.submitFromKeyboard()
        XCTAssertEqual(submissions, 0)
        XCTAssertTrue(editor.textView(editor, shouldChangeTextIn: NSRange(location: 0, length: 0), replacementText: "\n"))
        editor.unmarkText()
        editor.submitFromKeyboard()
        XCTAssertEqual(submissions, 1)
    }
}
