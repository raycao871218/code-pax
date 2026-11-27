import SwiftUI

/// App branding is independent of the assistant's character and custom avatar.
struct BrandMark: View {
    var body: some View {
        GeometryReader { geometry in
            Image("CodePaxLogo").resizable().interpolation(.high).scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: min(geometry.size.width, geometry.size.height) * 0.22))
        }.accessibilityHidden(true)
    }
}

/// Display Codex's character portrait or the user's custom avatar.
struct CodexPortrait: View {
    var body: some View { AssistantPortrait(agent: "codex") }
}

enum AssistantCharacter: String {
    case codex, claude
    var assetPrefix: String { self == .codex ? "CodePax" : "Claude" }
    var portraitAsset: String { self == .codex ? "CodePaxPortrait" : "ClaudePortrait" }
    var thinkingPrefix: String { self == .codex ? "CodePaxThinking" : "ClaudeThinking" }
}

struct AssistantPortrait: View {
    var agent: String = "codex"
    @ObservedObject private var store = CustomAvatarStore.shared
    var body: some View {
        GeometryReader { geometry in
            Group {
                if agent == "codex", let image = store.appearance.displayPortrait {
                    Image(uiImage: image).resizable().interpolation(.high).scaledToFill()
                } else if let character = AssistantCharacter(rawValue: agent) {
                    Image(character.portraitAsset).resizable().interpolation(.high).scaledToFit()
                } else {
                    Image(systemName: "terminal").resizable().scaledToFit().padding(10)
                }
            }.frame(width: geometry.size.width, height: geometry.size.height)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: min(geometry.size.width, geometry.size.height) * 0.22))
        }.accessibilityHidden(true)
    }
}
