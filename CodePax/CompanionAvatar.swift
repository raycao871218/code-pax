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
            if ["commandExecution", "fileChange", "webSearch", "mcpToolCall", "dynamicToolCall", "toolCall"].contains(active.kind) { return .executing }
            return .thinking
        default: return .idle
        }
    }
}

/// Timing for real, separately drawn hand/eye poses. The closed-eye frame is brief.
enum ThinkingFrames {
    // Two fully closed-eye frames make a brief 150ms blink, with short transitions.
    static let durations: [Double] = [0.75, 0.60, 0.06, 0.075, 0.075, 0.06, 0.65, 0.60]
    static var cycle: Double { durations.reduce(0, +) }
    static func index(elapsed: Double, enabled: Bool) -> Int {
        AvatarFrameTiming.index(elapsed: elapsed, durations: durations, enabled: enabled)
    }
}

enum CompanionMotion: String, CaseIterable {
    case thinking, typing, reading, replying, celebrating, focusing

    var durations: [Double] { ThinkingFrames.durations }
    var cycle: Double { durations.reduce(0, +) }
    func asset(for character: AssistantCharacter, frame: Int) -> String {
        let action = rawValue.prefix(1).uppercased() + String(rawValue.dropFirst())
        return "\(character.assetPrefix)\(action)\(frame)"
    }

    static func options(for state: CompanionState) -> [Self] {
        switch state {
        case .sending: return [.typing, .focusing]
        case .thinking: return [.thinking, .reading, .focusing]
        case .executing: return [.typing, .reading]
        case .replying: return [.replying, .focusing]
        case .completed: return [.celebrating]
        default: return []
        }
    }
}

struct CompanionMotionFrame: Equatable {
    let motion: CompanionMotion
    let index: Int
}

/// Rotate after two full loops, never switch randomly halfway through a pose.
enum CompanionMotionPlayback {
    static func frame(state: CompanionState, elapsed: Double, variant: Int, enabled: Bool) -> CompanionMotionFrame? {
        let options = CompanionMotion.options(for: state)
        guard !options.isEmpty else { return nil }
        let offset = (variant % options.count + options.count) % options.count
        guard enabled, elapsed.isFinite, elapsed >= 0 else {
            return CompanionMotionFrame(motion: options[offset], index: 0)
        }
        if state == .completed {
            let motion = CompanionMotion.celebrating
            let index = elapsed >= motion.cycle ? motion.durations.count - 1 : AvatarFrameTiming.index(elapsed: elapsed, durations: motion.durations, enabled: true)
            return CompanionMotionFrame(motion: motion, index: index)
        }
        let slotLength = ThinkingFrames.cycle * 2
        let slot = Int((elapsed / slotLength).rounded(.down).truncatingRemainder(dividingBy: Double(options.count)))
        let motion = options[(offset + slot) % options.count]
        let localTime = elapsed.truncatingRemainder(dividingBy: slotLength)
        return CompanionMotionFrame(motion: motion, index: AvatarFrameTiming.index(elapsed: localTime, durations: motion.durations, enabled: true))
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
    var agent: String = "codex"
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var started = Date()
    @State private var variant = Int.random(in: 0..<1024)
    @State private var celebrationFinished = false
    @ObservedObject private var store = CustomAvatarStore.shared
    @AppStorage("avatarAnimationSpeed") private var speed = 1.0
    var body: some View {
        let character = AssistantCharacter(rawValue: agent)
        let animation = agent == "codex" ? store.appearance.animation : nil
        let hasAnimation = animation != nil || (character != nil && (agent != "codex" || !store.appearance.isCustom))
        let celebrating = state == .completed && animation == nil && hasAnimation
        let showsAnimation = hasAnimation && !reduceMotion && (state.animates || celebrating)
        let playing = showsAnimation && scenePhase == .active && (!celebrating || !celebrationFinished)
        Group {
            if showsAnimation {
                TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !playing)) { context in
                    let elapsed = max(0, context.date.timeIntervalSince(started)) * min(2, max(0.5, speed))
                    Group {
                        if let animation {
                            let frame = AvatarFrameTiming.index(elapsed: elapsed, durations: animation.durations, enabled: playing)
                            Image(uiImage: animation.frames[frame]).resizable().interpolation(.high).scaledToFit()
                        } else if let character,
                                  let frame = CompanionMotionPlayback.frame(state: state, elapsed: celebrationFinished ? CompanionMotion.celebrating.cycle : elapsed, variant: variant, enabled: true) {
                            Image(frame.motion.asset(for: character, frame: frame.index)).resizable().interpolation(.high).scaledToFit()
                        }
                    }.clipShape(RoundedRectangle(cornerRadius: 10))
                }
            } else { AssistantPortrait(agent: agent) }
        }
        .accessibilityElement(children: .ignore).accessibilityLabel("\(cliAgentTitle(agent))，\(L10n.text(state.title))")
        .onChange(of: playing) { _, active in if active { started = Date() } }
        .onChange(of: state) { _, _ in
            started = Date(); celebrationFinished = false; variant = (variant + 1) % 1024
        }
        .task(id: playing && celebrating) {
            guard playing && celebrating else { return }
            let duration = CompanionMotion.celebrating.cycle / min(2, max(0.5, speed))
            do { try await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000)) }
            catch { return }
            celebrationFinished = true
        }
    }
}
