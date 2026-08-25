import UIKit

enum Device {
    static let id = UIDevice.current.identifierForVendor?.uuidString ?? "unknown"

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
