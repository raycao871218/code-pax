import SwiftUI

@main
struct CodexIPadApp: App {
    var body: some Scene {
        WindowGroup {
            Group {
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--preview-markdown-file") {
                    NavigationStack {
                        DownloadedFileContent(url: MarkdownFileContent.previewURL)
                            .navigationTitle("项目说明.md").navigationBarTitleDisplayMode(.inline)
                    }
                } else if ProcessInfo.processInfo.arguments.contains("--preview-terminal") {
                    TerminalPreviewScene()
                } else if ProcessInfo.processInfo.arguments.contains("--preview-customization") {
                    NavigationStack {
                        if ProcessInfo.processInfo.arguments.contains("--preview-avatar-guide") { AvatarCreationGuide() }
                        else { AppearanceCustomizationView() }
                    }
                } else { RootView() }
                #else
                RootView()
                #endif
            }.appAppearance()
        }
    }
}
