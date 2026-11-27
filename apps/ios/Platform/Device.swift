import UIKit

enum Device {
    static let hostKind = "ios"
    static var hostMode: String {
        #if targetEnvironment(simulator)
        "simulator"
        #else
        "device"
        #endif
    }
    static let id = UIDevice.current.identifierForVendor?.uuidString ?? "unknown"
    static var qualifiedID: String { "ios:\(id)" }
    @MainActor static var name: String { UIDevice.current.name }
    @MainActor static var localAgentName: String {
        UIDevice.current.userInterfaceIdiom == .pad ? L10n.string("This iPad") : L10n.string("This iPhone")
    }

    static let internalIDs: Set<String> = [
        "A73FE0BD-73EA-4916-AF12-BCD55D7A0F2D", // ox-qa simulator
        "6F2118DF-456E-4FA7-8152-E36075BE43DD", // Zi's iPhone 17 Pro Max
    ]

    static var isInternal: Bool {
        #if DEBUG
        return true
        #else
        return internalIDs.contains(id)
        #endif
    }
}
