import Foundation
import QuartzCore

@MainActor
final class IOSStreamFrameDriver: StreamFrameDriving {
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
