enum ServiceListOrder {
    private static let chatDomains = [
        "chatgpt.com",
        "claude.ai",
        "gemini.google.com",
        "grok.com",
        "chat.deepseek.com",
        "www.perplexity.ai",
        "copilot.com",
        "www.kimi.com",
        "qwen.ai",
        "doubao.com",
        "chat.z.ai",
        "muse.ai"
    ]

    static func rank(_ domain: String) -> Int {
        chatDomains.firstIndex(of: domain) ?? Int.max
    }
}
