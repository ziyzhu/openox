#if DEBUG
import Foundation

nonisolated enum OxAppStoreCreative {
    static let duration: TimeInterval = 20
    static let travelFraction: CGFloat = 0.5
    static let domains = [
        "chatgpt.com", "claude.ai", "gemini.google.com", "grok.com", "muse.ai",
        "manus.im", "www.kimi.com", "qwen.ai", "doubao.com", "chat.deepseek.com",
        "www.perplexity.ai", "copilot.com", "chat.z.ai",
    ]

    static func scrollProgress(at elapsed: TimeInterval) -> CGFloat {
        let phase = min(1, max(0, elapsed / duration)) * 2
        let position = min(phase, 2 - phase)
        let ramp = 0.15
        if position < ramp { return position * position / (2 * ramp * (1 - ramp)) }
        if position > 1 - ramp {
            let remaining = 1 - position
            return 1 - remaining * remaining / (2 * ramp * (1 - ramp))
        }
        return (position - ramp / 2) / (1 - ramp)
    }
}
#endif
