import AppKit

@MainActor
enum ExternalURL {
    static func open(_ url: URL) async -> Bool {
        NSWorkspace.shared.open(url)
    }
}
