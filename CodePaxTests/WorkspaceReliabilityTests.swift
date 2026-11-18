import XCTest
import UIKit
@testable import CodePax

final class WorkspaceReliabilityTests: XCTestCase {
    @MainActor
    func testMessageRetryRestoresOriginalRequestAndKeepsNewDraftSeparate() async throws {
        let connection = ConnectionModel()
        connection.profile.host = "retry-test-" + UUID().uuidString + ".invalid"
        let key = "workspace.\(connection.profile.endpoint).\(connection.profile.username)"
        let defaults = UserDefaults.standard
        defer {
            for suffix in [".outbox", ".pending", ".selection"] { defaults.removeObject(forKey: key + suffix) }
        }
        let suite = "retry-draft-" + UUID().uuidString
        let draftDefaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { draftDefaults.removePersistentDomain(forName: suite) }
        let original: [String: JSONValue] = ["action": .string("send"), "sessionId": .string("first"),
            "operationId": .string("original-operation"), "text": .string("原消息"),
            "model": .string("original-model"), "effort": .string("high"),
            "attachments": .array([.string("original-attachment")])]
        let submission = LocalSubmission(operationID: "original-operation", sessionID: "first", text: "原消息",
                                         state: "failed", request: original)
        defaults.set(try JSONEncoder().encode([submission]), forKey: key + ".outbox")
        let model = WorkspaceModel(connection: connection, defaults: draftDefaults)
        model.connectionChanged()
        await model.select("first")
        model.draft = "正在编辑的新草稿"
        XCTAssertEqual(model.retryRequest(for: submission.id), original)
        XCTAssertEqual(model.draft, "正在编辑的新草稿")
        XCTAssertNil(model.retryRequest(for: "local:another-operation"))
        await model.select("second")
        XCTAssertNil(model.retryRequest(for: submission.id))
        await model.select("first")
        XCTAssertEqual(model.draft, "正在编辑的新草稿")
        // Older outboxes can recover the exact operation from their pending record.
        let legacy = LocalSubmission(operationID: "original-operation", sessionID: "first", text: "原消息", state: "unknown")
        defaults.set(try JSONEncoder().encode([legacy]), forKey: key + ".outbox")
        defaults.set(try JSONEncoder().encode(original), forKey: key + ".pending")
        let restored = WorkspaceModel(connection: connection, defaults: draftDefaults)
        restored.connectionChanged()
        await restored.select("first")
        XCTAssertEqual(restored.retryRequest(for: submission.id), original)
        XCTAssertTrue(restored.isPendingMessage(submission.id))
        XCTAssertFalse(restored.isPendingMessage("local:another-operation"))
        defaults.removeObject(forKey: key + ".outbox")
        let pendingOnly = WorkspaceModel(connection: connection, defaults: draftDefaults)
        pendingOnly.connectionChanged()
        await pendingOnly.select("first")
        XCTAssertEqual(pendingOnly.localSubmissions.first?.id, submission.id)
        XCTAssertEqual(pendingOnly.retryRequest(for: submission.id), original)
    }

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
