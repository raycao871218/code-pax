import SwiftUI

/// Presentation only: derive presence from confirmed session state, never from old completed activity.
enum CompanionState: String, Equatable {
    case idle, sending, thinking, executing, replying, waiting, completed, failed, interrupted, offline, uncertain
    var title: String {
        switch self {
        case .idle: return "准备好开始工作"
        case .sending: return "正在发送任务"
        case .thinking: return "正在思考"
        case .executing: return "正在执行操作"
        case .replying: return "正在回复"
        case .waiting: return "等待你的确认"
        case .completed: return "回答完成"
        case .failed: return "任务遇到问题"
        case .interrupted: return "已停止"
        case .offline: return "连接已断开"
        case .uncertain: return "正在确认发送结果"
        }
    }
    var animates: Bool { [.sending, .thinking, .executing, .replying].contains(self) }
    static func resolve(connected: Bool, status: String?, messages: [CodexMessage], sending: Bool = false, uncertain: Bool = false, hasApprovals: Bool = false) -> Self {
        guard connected else { return .offline }
        if sending { return .sending }
        if uncertain { return .uncertain }
        if hasApprovals || status == "waiting" { return .waiting }
        switch status {
        case "completed": return .completed
        case "failed": return .failed
        case "interrupted": return .interrupted
        case "starting": return .thinking
        case "inProgress":
            // Only active items after the most recent user message belong to the current turn.
            let current = messages.suffix(from: messages.lastIndex(where: { $0.kind == "userMessage" }).map { $0 + 1 } ?? messages.startIndex)
            guard let active = current.last(where: { ["inProgress", "starting"].contains($0.status) }) else { return .thinking }
            if active.kind == "agentMessage" { return .replying }
            if ["commandExecution", "fileChange", "webSearch", "mcpToolCall", "dynamicToolCall"].contains(active.kind) { return .executing }
            return .thinking
        default: return .idle
        }
    }
}

/// Timing for real, separately drawn hand/eye poses. The closed-eye frame is brief.
enum ThinkingFrames {
    static let durations: [Double] = [0.65, 0.70, 0.16, 0.55]
    static var cycle: Double { durations.reduce(0, +) }
    static func index(elapsed: Double, enabled: Bool) -> Int {
        AvatarFrameTiming.index(elapsed: elapsed, durations: durations, enabled: enabled)
    }
}

/// Only the newest assistant reply in the current turn gets an animated portrait.
enum CompanionReplyPolicy {
    static func latestReplyID(in messages: [CodexMessage]) -> String? {
        let start = messages.lastIndex(where: { $0.kind == "userMessage" }).map { $0 + 1 } ?? 0
        return messages.suffix(from: start).last(where: { $0.kind == "agentMessage" })?.id
    }
    static func displayedMessages(_ messages: [CodexMessage], state: CompanionState) -> [CodexMessage] {
        guard state.animates, latestReplyID(in: messages) == nil,
              let user = messages.last(where: { $0.kind == "userMessage" }) else { return messages }
        // The normal reply starts with its avatar before text arrives; no extra status card.
        return messages + [CodexMessage(id: "local-reply-avatar-" + user.id, kind: "agentMessage", text: "", status: "inProgress")]
    }
}

struct CompanionAvatar: View {
    let state: CompanionState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var started = Date()
    @ObservedObject private var store = CustomAvatarStore.shared
    @AppStorage("avatarAnimationSpeed") private var speed = 1.0
    var body: some View {
        let animation = store.appearance.animation
        let hasAnimation = animation != nil || !store.appearance.isCustom
        let playing = state.animates && hasAnimation && !reduceMotion && scenePhase == .active
        Group {
            if state.animates && hasAnimation {
                TimelineView(.animation(minimumInterval: 0.06, paused: !playing)) { context in
                    let frame = AvatarFrameTiming.index(elapsed: context.date.timeIntervalSince(started) * min(2, max(0.5, speed)), durations: animation?.durations ?? ThinkingFrames.durations, enabled: playing)
                    Group {
                        if let animation { Image(uiImage: animation.frames[frame]).resizable().interpolation(.high).scaledToFit() }
                        else { Image("CodePaxThinking\(frame)").resizable().interpolation(.high).scaledToFit() }
                    }.clipShape(RoundedRectangle(cornerRadius: 10))
                }
            } else { BrandMark() }
        }
        .accessibilityElement(children: .ignore).accessibilityLabel("Code Pax，\(state.title)")
        .onChange(of: playing) { _, active in if active { started = Date() } }
    }
}
