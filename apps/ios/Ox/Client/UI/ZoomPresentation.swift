import SwiftUI

@Observable
final class ZoomPresentation<Item> {
    private enum Phase {
        case idle
        case presented(Item)
        case dismissing(Item)
    }

    private let owner: String
    private let itemDescription: (Item) -> String
    private var phase: Phase

    init(
        owner: String,
        initialItem: Item? = nil,
        itemDescription: @escaping (Item) -> String
    ) {
        self.owner = owner
        self.itemDescription = itemDescription
        phase = initialItem.map(Phase.presented) ?? .idle
    }

    var binding: Binding<Item?> {
        Binding(
            get: { self.presentedItem },
            set: { item in
                if let item {
                    self.present(item)
                } else {
                    self.dismiss()
                }
            }
        )
    }

    var isDismissing: Bool {
        guard case .dismissing = phase else { return false }
        return true
    }

    func present(_ item: Item) {
        guard case .idle = phase else { return }
        phase = .presented(item)
        Log.ui.info("ZoomPresentation.presented owner=\(owner) item=\(itemDescription(item))")
    }

    func dismiss() {
        guard case .presented(let item) = phase else { return }
        phase = .dismissing(item)
        Log.ui.info("ZoomPresentation.dismissal-started owner=\(owner) item=\(itemDescription(item))")
    }

    func finishDismissal(perform: ((Item) -> Void)? = nil) {
        guard case .dismissing(let item) = phase else { return }
        phase = .idle
        Log.ui.info("ZoomPresentation.dismissal-finished owner=\(owner) item=\(itemDescription(item))")
        perform?(item)
    }

    private var presentedItem: Item? {
        guard case .presented(let item) = phase else { return nil }
        return item
    }
}
