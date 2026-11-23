import SwiftUI

/// Pixel rendition of Claude Code's orange Clawd terminal mascot.
/// Reference silhouette: anthropics/claude-code issue 24926 (startup banner).
/// Separate leg/eye poses keep pixels crisp without scaling or continuous bobbing.
struct ClaudeAvatar: View {
    var state: CompanionState = .idle
    var animated = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var started = Date()

    private var playing: Bool { animated && !reduceMotion && scenePhase == .active }

    var body: some View {
        TimelineView(.animation(minimumInterval: state.animates ? 0.22 : 0.5, paused: !playing)) { context in
            let elapsed = playing ? context.date.timeIntervalSince(started) : 0
            Canvas { context, size in
                let unit = floor(min(size.width / 18, size.height / 15) * 2) / 2
                let origin = CGPoint(x: (size.width - unit * 18) / 2, y: (size.height - unit * 15) / 2)
                let phase = ClaudeAvatarPose.phase(elapsed: elapsed, state: state, animated: playing)
                let orange = Color(red: 0.85, green: 0.47, blue: 0.34)
                let ink = Color(red: 0.18, green: 0.14, blue: 0.12)
                func pixel(_ x: Int, _ y: Int, _ width: Int = 1, _ height: Int = 1, color: Color = orange) {
                    let rect = CGRect(x: origin.x + CGFloat(x) * unit, y: origin.y + CGFloat(y) * unit,
                                      width: CGFloat(width) * unit, height: CGFloat(height) * unit)
                    context.fill(Path(rect), with: .color(color))
                }
                pixel(4, 3, 10, 7)
                pixel(3, 4, 1, 5); pixel(14, 4, 1, 5)
                let raised = state == .waiting || (state.animates && phase == 1)
                pixel(1, raised ? 4 : 6, 2, 3); pixel(15, raised ? 4 : 6, 2, 3)
                pixel(2, raised ? 3 : 8); pixel(15, raised ? 3 : 8)
                let step = state.animates && phase == 1 ? 1 : 0
                pixel(4 - step, 10, 2, 2); pixel(7, 10, 1, 2 - step)
                pixel(10, 10, 1, 2 - step); pixel(12 + step, 10, 2, 2)
                let blink = phase == 2 || state == .offline
                pixel(6, blink ? 6 : 5, 1, blink ? 1 : 2, color: ink)
                pixel(11, blink ? 6 : 5, 1, blink ? 1 : 2, color: ink)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Claude，\(L10n.text(state.title))")
        .onChange(of: playing) { _, _ in started = Date() }
        .onChange(of: state) { _, _ in started = Date() }
    }
}

enum ClaudeAvatarPose {
    static func phase(elapsed: Double, state: CompanionState, animated: Bool) -> Int {
        guard animated, elapsed.isFinite, elapsed >= 0 else { return 0 }
        if state.animates {
            return [0, 1, 0, 2][Int(elapsed / 0.35) % 4]
        }
        // One brief blink per quiet cycle; completed/failed replies do not dance.
        return elapsed.truncatingRemainder(dividingBy: 4.5) >= 4.2 ? 2 : 0
    }
}
