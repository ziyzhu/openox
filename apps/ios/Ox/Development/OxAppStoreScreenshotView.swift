#if DEBUG
import SwiftUI

nonisolated enum OxAppStoreScreenshot: String, CaseIterable {
    case planning, publishing, memory, reminder, service, post

    var scene: OxDemoScene {
        switch self {
        case .planning: .planning
        case .publishing: .publishing
        case .memory: .memory
        case .reminder: .offline
        case .service: .reddit
        case .post: .reuse
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
        OxDemoSceneView(scene: screenshot.scene, completed: true, presentation: .appStore)
    }
}

#Preview("App Store 01 · Send and schedule") {
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

#Preview("App Store 05 · Create a reusable service") {
    OxAppStoreScreenshotView(screenshot: .service)
}

#Preview("App Store 06 · Publish with your service") {
    OxAppStoreScreenshotView(screenshot: .post)
}
#endif
