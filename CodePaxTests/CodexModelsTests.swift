import XCTest
import SwiftUI
import UIKit
@testable import CodePax

final class CodexModelsTests: XCTestCase {
    func testAttachmentLimitsAndAttachmentOnlyMessage() throws {
        XCTAssertThrowsError(try AttachmentPolicy.validate(size: 0, count: 0))
        XCTAssertThrowsError(try AttachmentPolicy.validate(size: AttachmentPolicy.maximumSize + 1, count: 0))
        XCTAssertThrowsError(try AttachmentPolicy.validate(size: 1, count: 8))
        XCTAssertNoThrow(try AttachmentPolicy.validate(size: AttachmentPolicy.maximumSize, count: 7))
        XCTAssertEqual(AttachmentPolicy.displayText("", names: ["a.pdf"]), "📎 a.pdf")
        XCTAssertEqual(AttachmentPolicy.displayText("检查", names: ["a.png", "b.txt"]), "检查\n\n📎 a.png\n\n📎 b.txt")
        let original = UploadedAttachment(id: "a", name: "a.pdf", size: 23, kind: "file", path: "/project/a.pdf")
        let restored = try JSONDecoder().decode(UploadedAttachment.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(restored.id, original.id)
        XCTAssertEqual(restored.symbol, "doc")
        XCTAssertNil(restored.uploadPath)
    }

    func testCompletionReceiptsTrackNewTurnsAndOnlyReadMatchingVisibleAnswer() throws {
        var reads = CompletionReads()
        reads.observe(id: "history", completedTurnID: "old")
        XCTAssertFalse(reads.isUnread("history"))
        reads.observe(id: "chat", completedTurnID: nil)
        reads.observe(id: "chat", completedTurnID: "turn1")
        XCTAssertTrue(reads.isUnread("chat"))
        reads.markRead(id: "history", completedTurnID: "old")
        XCTAssertTrue(reads.isUnread("chat"))
        reads.observe(id: "chat", completedTurnID: nil) // Running/interrupted updates preserve unread.
        XCTAssertTrue(reads.isUnread("chat"))
        reads.observe(id: "chat", completedTurnID: "turn2")
        reads.markRead(id: "chat", completedTurnID: "turn1") // Stale detail cannot read a newer answer.
        XCTAssertTrue(reads.isUnread("chat"))
        reads = try JSONDecoder().decode(CompletionReads.self, from: JSONEncoder().encode(reads))
        XCTAssertTrue(reads.isUnread("chat"))
        reads.markRead(id: "chat", completedTurnID: "turn2")
        XCTAssertFalse(reads.isUnread("chat"))
        reads.observe(id: "chat", completedTurnID: "turn2") // Repeated polling does not re-notify.
        XCTAssertFalse(reads.isUnread("chat"))
        XCTAssertFalse(CompletionReads().isUnread("chat"))
    }

    func testCompletionMarkerDecodesFromSnapshot() throws {
        let json = """
        {"sessions":[{"id":"a","title":"A","cwd":"/tmp","status":"completed",
         "updatedAt":0,"completedTurnId":"turn1"}],"ready":true}
        """
        let snapshot = try JSONDecoder().decode(CodexSnapshot.self, from: Data(json.utf8))
        XCTAssertEqual(snapshot.sessions.first?.completedTurnId, "turn1")
    }

    func testUsageRefreshIsImmediateThenDueEveryMinute() {
        let start = Date(timeIntervalSince1970: 1000)
        var schedule = UsageRefreshSchedule()
        XCTAssertTrue(schedule.isDue(at: start))
        schedule.recordAttempt(at: start)
        XCTAssertFalse(schedule.isDue(at: start.addingTimeInterval(59.99)))
        XCTAssertTrue(schedule.isDue(at: start.addingTimeInterval(60)))
        schedule.recordAttempt(at: start.addingTimeInterval(60))
        XCTAssertFalse(schedule.isDue(at: start.addingTimeInterval(119.99)))
        XCTAssertTrue(schedule.isDue(at: start.addingTimeInterval(120)))
        schedule = UsageRefreshSchedule()  // Reconnecting requires a fresh initial read.
        XCTAssertTrue(schedule.isDue(at: start.addingTimeInterval(121)))
    }

    func testUsageIconUsesLowestRemainingWindowAndDoesNotInventUnknownQuota() throws {
        let json = """
        {"rateLimits":{"primary":{"usedPercent":1}},"rateLimitsByLimitId":{
          "codex":{"primary":{"usedPercent":85},"secondary":{"usedPercent":95}},
          "other":{"primary":{"usedPercent":10}}
        }}
        """
        let usage = try JSONDecoder().decode(AccountUsage.self, from: Data(json.utf8))
        XCTAssertEqual(usage.severity, .critical)
        let warning = AccountUsage(rateLimits: RateLimitBucket(limitId: nil, limitName: nil,
            primary: RateLimitWindow(usedPercent: 90, windowDurationMins: nil, resetsAt: nil), secondary: nil, planType: nil),
            rateLimitsByLimitId: nil, threadUsage: nil, updatedAt: nil, error: nil)
        XCTAssertEqual(warning.severity, .warning)
        let unknown = try JSONDecoder().decode(AccountUsage.self, from: Data("{}".utf8))
        XCTAssertNil(unknown.severity)
    }
    func testUsageThresholdsUseRemainingQuotaAndStrictBoundaries() {
        let cases: [(Double, UsageSeverity)] = [(0, .critical), (9.99, .critical), (10, .warning),
                                               (19.99, .warning), (20, .normal), (100, .normal)]
        for (remaining, severity) in cases {
            let window = RateLimitWindow(usedPercent: 100 - remaining, windowDurationMins: nil, resetsAt: nil)
            XCTAssertEqual(window.severity, severity, "Remaining: \(remaining)")
        }
    }

    @MainActor
    func testAppearanceUpdatesAlreadyPresentedPageWithoutNavigation() async throws {
        let suite = "appearance-test-" + UUID().uuidString
        let store = try XCTUnwrap(UserDefaults(suiteName: suite))
        store.set("dark", forKey: "appearance")
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let presenter = UIViewController()
        window.rootViewController = presenter
        window.makeKeyAndVisible()
        try await Task.sleep(for: .milliseconds(100))
        let page = UIHostingController(rootView: Text("Current page").appAppearance(store: store))
        page.modalPresentationStyle = .fullScreen
        presenter.present(page, animated: false)
        defer {
            presenter.dismiss(animated: false)
            window.isHidden = true
            store.removePersistentDomain(forName: suite)
        }
        for _ in 0..<20 where page.traitCollection.userInterfaceStyle != .dark {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(page.traitCollection.userInterfaceStyle, .dark)
        store.set("light", forKey: "appearance")
        for _ in 0..<20 where page.traitCollection.userInterfaceStyle != .light {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(page.traitCollection.userInterfaceStyle, .light)
        store.set("dark", forKey: "appearance")
        for _ in 0..<20 where page.traitCollection.userInterfaceStyle != .dark {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(page.traitCollection.userInterfaceStyle, .dark)
        XCTAssertTrue(presenter.presentedViewController === page)
        store.set("system", forKey: "appearance")
        for _ in 0..<20 where window.overrideUserInterfaceStyle != .unspecified {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(window.overrideUserInterfaceStyle, .unspecified)
    }
    func testCompletionOnlyAppearsAfterExplicitSuccessAndReturnsToSendWhenTyping() {
        XCTAssertEqual(ComposerState.resolve(status: "completed", draft: "", sending: false, pending: false), .completed)
        XCTAssertEqual(ComposerState.resolve(status: "completed", draft: "Next", sending: false, pending: false), .ready)
        XCTAssertEqual(ComposerState.resolve(status: "completed", draft: "", sending: true, pending: true), .sending)
        XCTAssertEqual(ComposerState.resolve(status: "completed", draft: "", sending: false, pending: true), .ready)
        for status in ["failed", "interrupted", "unknown", "idle"] {
            XCTAssertEqual(ComposerState.resolve(status: status, draft: "", sending: false, pending: false), .ready)
        }
        for status in ["inProgress", "starting", "waiting"] {
            XCTAssertEqual(ComposerState.resolve(status: status, draft: "Next", sending: false, pending: false), .running)
        }
    }

    func testUsageDecodesBucketsAndClampsRemainingPercent() throws {
        let json = """
        {"rateLimits":{"primary":{"usedPercent":20}},"rateLimitsByLimitId":{
          "codex":{"primary":{"usedPercent":105,"windowDurationMins":300,"resetsAt":123}},
          "other":{"secondary":{"usedPercent":-3,"windowDurationMins":10080}}
        },"threadUsage":null,"updatedAt":null,"error":null}
        """
        let usage = try JSONDecoder().decode(AccountUsage.self, from: Data(json.utf8))
        XCTAssertEqual(usage.buckets.count, 2)
        XCTAssertEqual(usage.buckets[0].value.primary?.remainingPercent, 0)
        XCTAssertEqual(usage.buckets[0].value.primary?.title, "5 小时额度")
        XCTAssertEqual(usage.buckets[1].value.secondary?.remainingPercent, 100)
        XCTAssertEqual(usage.buckets[1].value.secondary?.title, "7 天额度")
        XCTAssertNil(usage.threadUsage)
    }

    func testContextUsageUsesLastRequestRatherThanCumulativeTokens() {
        let total = TokenBreakdown(totalTokens: 999999, inputTokens: 900000, cachedInputTokens: 600000,
                                   outputTokens: 99999, reasoningOutputTokens: 1000)
        let last = TokenBreakdown(totalTokens: 10000, inputTokens: 9000, cachedInputTokens: 5000,
                                  outputTokens: 1000, reasoningOutputTokens: 400)
        XCTAssertEqual(ThreadTokenUsage(total: total, last: last, modelContextWindow: 200000).contextFraction, 0.05)
        XCTAssertNil(ThreadTokenUsage(total: total, last: last, modelContextWindow: nil).contextFraction)
        XCTAssertNil(ThreadTokenUsage(total: total, last: last, modelContextWindow: 0).contextFraction)
    }
    func testLocalMessageAppearsBeforeServerAcknowledgementAndMergesOnce() throws {
        let local = LocalSubmission(operationID: "operation", sessionID: "chat", text: "Hello", state: "sending")
        let immediate = MessageTimeline.merge(remote: [], local: [local], sessionID: "chat")
        XCTAssertEqual(immediate.map(\.text), ["Hello"])
        XCTAssertEqual(immediate.first?.status, "sending")
        let accepted = CodexMessage(id: local.id, kind: "userMessage", text: "Hello", status: "accepted")
        let merged = MessageTimeline.merge(remote: [accepted], local: [local], sessionID: "chat")
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.status, "accepted")
        XCTAssertTrue(MessageTimeline.merge(remote: [], local: [local], sessionID: "other-chat").isEmpty)
        let restored = try JSONDecoder().decode(LocalSubmission.self, from: JSONEncoder().encode(local))
        XCTAssertEqual(restored.id, local.id)
    }

    func testIdenticalMessagesWithDifferentOperationIDsAreKept() {
        let first = LocalSubmission(operationID: "first", sessionID: "chat", text: "Again", state: "accepted")
        let second = LocalSubmission(operationID: "second", sessionID: "chat", text: "Again", state: "sending")
        let messages = MessageTimeline.merge(remote: [first.message], local: [first, second], sessionID: "chat")
        XCTAssertEqual(messages.map(\.id), [first.id, second.id])
        XCTAssertEqual(messages.map(\.status), ["accepted", "sending"])
    }
    func testConsecutiveActivitiesCollapseWithoutHidingConversationOrder() {
        let messages = [
            CodexMessage(id: "user", kind: "userMessage", text: "Run tests", status: "completed"),
            CodexMessage(id: "cmd1", kind: "commandExecution", text: "pwd", status: "completed"),
            CodexMessage(id: "cmd2", kind: "commandExecution", text: "swift test", status: "inProgress"),
            CodexMessage(id: "file", kind: "fileChange", text: "Sources/App.swift", status: "completed"),
            CodexMessage(id: "reply", kind: "agentMessage", text: "Done", status: "completed"),
            CodexMessage(id: "cmd3", kind: "commandExecution", text: "git status", status: "completed")
        ]
        let entries = ConversationEntry.group(messages)
        XCTAssertEqual(entries.map(\.id), ["user", "cmd1", "reply", "cmd3"])
        XCTAssertEqual(entries[1].messages.map(\.id), ["cmd1", "cmd2", "file"])
        XCTAssertTrue(entries[1].isRunning)
        XCTAssertEqual(entries[1].summary, "正在执行 · 2 条命令 · 1 次文件更新")
        XCTAssertFalse(entries[2].isActivity)
        XCTAssertTrue(ConversationEntry.group([]).isEmpty)
    }

    func testActivityIdentityRemainsStableAsOutputStreams() {
        let first = CodexMessage(id: "cmd", kind: "commandExecution", text: "ls\nfile", status: "inProgress")
        let final = CodexMessage(id: "cmd", kind: "commandExecution", text: "ls\nfile\nother", status: "completed")
        XCTAssertEqual(ConversationEntry.group([first])[0].id, ConversationEntry.group([final])[0].id)
        XCTAssertEqual(final.activityTitle, "ls")
        XCTAssertFalse(ConversationEntry.group([final])[0].isRunning)
    }
    func testShellQuotingCannotInjectCommands() {
        XCTAssertEqual(RemoteShell.quote("it's $(touch /tmp/example)"), "'it'\"'\"'s $(touch /tmp/example)'")
        XCTAssertEqual(RemoteShell.quote(""), "''")
    }

    func testJSONRoundTripPreservesMixedApprovalPayload() throws {
        let payload = """
        {"id":42,"method":"item/commandExecution/requestApproval","params":{"command":"echo test","availableDecisions":["accept","decline"],"optional":null}}
        """
        let original = try JSONDecoder().decode(JSONValue.self, from: Data(payload.utf8))
        let decoded = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded["params"]["command"].string, "echo test")
    }

    func testFailedAndInterruptedAreNotRunning() throws {
        for state in ["failed", "completed", "interrupted"] {
            let json = """
            {"id":"thread-1","title":"Demo","cwd":"/tmp/demo","status":"\(state)","turnId":null,"messages":[],"approvals":[],"diff":"","error":null,"historyTruncated":false}
            """
            let session = try JSONDecoder().decode(CodexSession.self, from: Data(json.utf8))
            XCTAssertFalse(session.isRunning)
        }
    }
}
