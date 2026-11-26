import UIKit

@MainActor
enum ExternalURL {
    static func open(_ url: URL) async -> Bool {
        await UIApplication.shared.open(url)
    }
}
