import Foundation
import SwiftUI

@MainActor
final class CollaborationModel: ObservableObject {
    @Published private(set) var runs: [CollaborationRun] = []
    @Published private(set) var isBusy = false
    @Published private(set) var error: String?
    @Published private(set) var hasPendingOperation = false
    let workspace: WorkspaceModel
    private let serverKey: String
    private let pendingStore = CollaborationPendingStore()
    private var refreshing = false
    private var focusedRunID: String?

    init(workspace: WorkspaceModel) {
        self.workspace = workspace
        serverKey = workspace.connection.profile.credentialAccount
        do { hasPendingOperation = try pendingStore.read(serverKey) != nil }
        catch { self.error = error.localizedDescription; hasPendingOperation = true }
    }

    var isAvailable: Bool {
        workspace.isPrepared && workspace.supportsCollaboration && workspace.connection.isConnected &&
        workspace.connection.profile.credentialAccount == serverKey
    }
    var canAct: Bool { isAvailable && !isBusy && !hasPendingOperation }

    private func request<Value: Decodable>(_ fields: [String: JSONValue]) async throws -> Value {
        guard isAvailable else { throw ConnectionError.message("协作后台未就绪，请连接并准备工作区。") }
        let result: Value = try await workspace.connection.runBridge(mode: "call", fields: fields)
        guard workspace.connection.profile.credentialAccount == serverKey else { throw CancellationError() }
        return result
    }

    func refresh() async {
        guard isAvailable, !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        do {
            let result: CollaborationCatalog = try await request(["action": .string("teamList")])
            var updated = result.runs
            if let focusedRunID {
                let detail: CollaborationRun = try await request(["action": .string("teamRead"), "runId": .string(focusedRunID)])
                if let index = updated.firstIndex(where: { $0.id == focusedRunID }) { updated[index] = detail }
                else { updated.insert(detail, at: 0) }
            }
            runs = updated
        } catch { self.error = error.localizedDescription }
    }

    func poll() async {
        while !Task.isCancelled {
            await refresh()
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
        }
    }

    func focus(_ runID: String) async { focusedRunID = runID; await refresh() }
    func unfocus(_ runID: String) { if focusedRunID == runID { focusedRunID = nil } }

    @discardableResult
    func perform(_ fields: [String: JSONValue]? = nil) async -> Bool {
        guard isAvailable, !isBusy else { return false }
        if fields != nil && hasPendingOperation { return false }
        isBusy = true
        error = nil
        defer { isBusy = false }
        do {
            let operation: [String: JSONValue]
            if let fields {
                var body = fields
                body["operationId"] = .string(UUID().uuidString)
                try pendingStore.save(JSONEncoder().encode(body), key: serverKey)
                operation = body
            } else {
                guard let pending = try pendingStore.read(serverKey) else { hasPendingOperation = false; return false }
                operation = try JSONDecoder().decode([String: JSONValue].self, from: pending)
            }
            hasPendingOperation = true
            let _: JSONValue = try await request(operation)
            try pendingStore.remove(serverKey)
            hasPendingOperation = false
            await refresh()
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    func discardPending() {
        do { try pendingStore.remove(serverKey); hasPendingOperation = false; error = nil }
        catch { self.error = error.localizedDescription }
    }

    func create(cwd: String, goal: String, tasks: [CollaborationTaskDraft], maxWorkers: Int) async -> Bool {
        var fields: [String: JSONValue] = ["action": .string("teamCreate"), "cwd": .string(cwd), "goal": .string(goal),
            "maxWorkers": .number(Double(maxWorkers)), "accessMode": .string(workspace.accessMode.rawValue),
            "tasks": .array(tasks.map { .object(["title": .string($0.title), "prompt": .string($0.prompt)]) })]
        if !workspace.selectedModel.isEmpty {
            fields["model"] = .string(workspace.selectedModel)
            if !workspace.selectedEffort.isEmpty { fields["effort"] = .string(workspace.selectedEffort) }
        }
        return await perform(fields)
    }

    func diff(runID: String, taskID: String) async throws -> CollaborationDiff {
        try await request(["action": .string("teamDiff"), "runId": .string(runID), "taskId": .string(taskID)])
    }
}
