import Observation
import SwiftUI
import UIKit

@MainActor
@Observable
final class CopyFeedback {
    private(set) var didCopy = false
    @ObservationIgnored private var resetTask: Task<Void, Never>?

    func copy(_ text: String, logMessage: String) {
        UIPasteboard.general.string = text
        Log.ui.info("\(logMessage)")
        Haptics.impact(.copy)
        resetTask?.cancel()
        withAnimation(.easeOut(duration: Theme.Animation.quick)) { didCopy = true }
        resetTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self else { return }
            withAnimation(.easeOut(duration: Theme.Animation.quick)) { didCopy = false }
        }
    }
}
