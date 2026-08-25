import Foundation
import QuartzCore

@MainActor
final class OutputDelivery {
    enum Visibility {
        case visible
        case hidden
    }

    enum Completion {
        case open
        case ending(AssistantMessage)
    }

    struct Checkpoint {
        let text: String
        let completion: AssistantMessage?
    }

    private var chunks: [String] = []
    private(set) var visibility: Visibility = .hidden
    private(set) var completion: Completion = .open

    var needsFrames: Bool {
        visibility == .visible && (hasText || isEnding)
    }

    private var hasText: Bool { !chunks.isEmpty }

    private var isEnding: Bool {
        if case .ending = completion { true } else { false }
    }

    func setVisibility(_ visibility: Visibility) {
        self.visibility = visibility
    }

    func append(_ text: String) {
        if !text.isEmpty { chunks.append(text) }
    }

    func drainText() -> String {
        let text = chunks.joined()
        clearText()
        return text
    }

    func end(_ message: AssistantMessage) {
        completion = .ending(message)
    }

    func discardText() {
        clearText()
    }

    func nextFrame(at _: CFTimeInterval) -> Checkpoint? {
        if hasText {
            let text = chunks.joined()
            clearText()
            return Checkpoint(text: text, completion: nil)
        }
        guard case .ending(let message) = completion else { return nil }
        completion = .open
        return Checkpoint(text: "", completion: message)
    }

    func hiddenCheckpoint() -> Checkpoint? {
        guard visibility == .hidden else { return nil }
        let text = chunks.joined()
        clearText()
        let message: AssistantMessage?
        if case .ending(let ending) = completion {
            message = ending
            completion = .open
        } else {
            message = nil
        }
        return text.isEmpty && message == nil ? nil : Checkpoint(text: text, completion: message)
    }

    func reset() {
        clearText()
        completion = .open
    }

    private func clearText() {
        chunks.removeAll(keepingCapacity: true)
    }
}

@MainActor
final class StreamFrameDriver {
    private var link: CADisplayLink?
    private let handler: @MainActor (CFTimeInterval) -> Void

    init(handler: @escaping @MainActor (CFTimeInterval) -> Void) {
        self.handler = handler
    }

    func start() -> Bool {
        guard link == nil else { return false }
        let proxy = StreamFrameProxy(handler)
        let link = CADisplayLink(target: proxy, selector: #selector(StreamFrameProxy.fire))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
        link.add(to: .main, forMode: .common)
        self.link = link
        return true
    }

    func stop() -> Bool {
        guard link != nil else { return false }
        link?.invalidate()
        link = nil
        return true
    }
}

@MainActor
private final class StreamFrameProxy: NSObject {
    private let handler: @MainActor (CFTimeInterval) -> Void

    init(_ handler: @escaping @MainActor (CFTimeInterval) -> Void) {
        self.handler = handler
    }

    @objc func fire(_ link: CADisplayLink) {
        handler(link.timestamp)
    }
}
