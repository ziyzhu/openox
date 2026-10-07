#if DEBUG
import SwiftUI

nonisolated enum OxAppStoreScreenshot: String, CaseIterable {
    case planning, publishing, memory, reminder, service, research

    var scene: OxDemoScene {
        switch self {
        case .planning: .planning
        case .publishing: .publishing
        case .memory: .memory
        case .reminder: .offline
        case .service: .reddit
        case .research: .memory
        }
    }

    var conversation: OxDemoConversation {
        switch self {
        case .planning:
            .init(
                prompt: "Use my ChatGPT and Muse launch plans and Alex's latest Outlook email to save a release checklist in Ox.",
                domains: ["chatgpt.com", "muse.ai", "outlook.live.com"],
                reply: """
                Created **Release checklist** from your ChatGPT and Muse plans and Alex's Outlook email.

                - **Before launch:** finish smoke checks and release notes.
                - **Review:** confirm Alex's sign-off.
                - **After launch:** check errors and feedback.

                Saved as `release-checklist.md` in this Profile. Nothing was sent.
                """,
                progress: ["Reading launch plans from ChatGPT and Muse", "Checking Alex's release email in Outlook", "Saving the combined release checklist in Ox"]
            )
        case .service:
            .init(
                prompt: "Post to my Reddit profile: one task, 45 minutes of focus, no notifications.",
                domains: [],
                reply: """
                Posted **My focused-morning routine** to your Reddit profile after your approval.

                Reddit wasn't installed, so I created and saved a reusable **Reddit** service in Local, then used it to publish your post.

                It's attached and ready for your next Reddit task.
                """,
                progress: ["Inspecting Reddit's profile posting flow", "Creating and validating a reusable Reddit service in Local", "Publishing your post after approval"]
            )
        case .research:
            .init(
                prompt: "Research where to stay in Kyoto with Gemini, Claude, and Grok. Compare their recommendations and save a brief.",
                domains: ["gemini.google.com", "claude.ai", "grok.com"],
                reply: """
                Saved **Where to stay in Kyoto** in this Profile.

                - **Gemini:** Kyoto Station for easy arrivals and day trips.
                - **Claude:** Gion / Higashiyama for atmosphere and walkable sights.
                - **Grok:** Downtown Kyoto for restaurants and transit.

                **My pick:** Downtown Kyoto for a first visit. Kyoto Station is the practical alternative.

                The brief keeps each assistant's reasoning and trade-offs.
                """,
                progress: ["Researching Kyoto neighborhoods with Gemini, Claude, and Grok", "Comparing recommendations and trade-offs", "Saving the combined research brief in Ox"]
            )
        default: scene.conversation
        }
    }
}

nonisolated enum OxAppStoreScreenshotLaunch {
    static var enabled: Bool { ProcessInfo.processInfo.environment["OX_APP_STORE_SCREENSHOT"] != nil }
    static var screenshot: OxAppStoreScreenshot {
        OxAppStoreScreenshot(rawValue: ProcessInfo.processInfo.environment["OX_APP_STORE_SCREENSHOT"] ?? "") ?? .planning
    }
}

struct OxAppStoreScreenshotView: View {
    let screenshot: OxAppStoreScreenshot

    var body: some View {
        OxDemoSceneView(scene: screenshot.scene, completed: true, presentation: .appStore(screenshot))
    }
}

#Preview("App Store 01 · Connect ChatGPT, Muse, and Outlook") {
    OxAppStoreScreenshotView(screenshot: .planning)
}

#Preview("App Store 02 · Open and share a pull request") {
    OxAppStoreScreenshotView(screenshot: .publishing)
}

#Preview("App Store 03 · Import memory") {
    OxAppStoreScreenshotView(screenshot: .memory)
}

#Preview("App Store 04 · Add an on-device reminder") {
    OxAppStoreScreenshotView(screenshot: .reminder)
}

#Preview("App Store 05 · Complete a Reddit task and create its service") {
    OxAppStoreScreenshotView(screenshot: .service)
}

#Preview("App Store 06 · Research across Gemini, Claude, and Grok") {
    OxAppStoreScreenshotView(screenshot: .research)
}
#endif
