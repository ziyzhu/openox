import Foundation

nonisolated enum ProviderIcon {
    private static let assets = [
        "chatgpt": "openai",
        "openai": "openai",
        "anthropic": "anthropic",
        "gemini": "gemini",
        "github-copilot": "github-copilot",
        "xai": "xai",
        "opencode-go": "opencode",
        "qwen-coding-plan": "qwen",
        "qwen": "qwen",
        "minimax-token-plan": "minimax",
        "minimax": "minimax",
        "openrouter": "openrouter",
        "amazon-bedrock": "amazon-bedrock",
        "mistral": "mistral",
        "kimi": "kimi",
        "deepseek": "deepseek",
        "zai-coding-plan": "zai",
        "zai": "zai",
        "stepfun": "stepfun",
        "siliconflow": "siliconflow",
        "tencent-tokenhub": "tencent-tokenhub",
        "modelscope": "modelscope",
    ]

    static func url(id: String, website: URL?) -> URL? {
        let providerID = id.components(separatedBy: ":")[0]
        let asset = providerID == "ark"
            ? (website?.host == "console.volcengine.com" ? "volcengine" : "byteplus")
            : assets[providerID]
        guard let asset else { return nil }
        return URL(string: "https://openox.ai/assets/services/model-providers/\(asset)/favicon.png")
    }
}
