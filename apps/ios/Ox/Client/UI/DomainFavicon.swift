import SwiftUI

struct DomainFavicon: View {
    let domain: String
    let size: CGFloat
    var overrideURL: URL? = nil

    var body: some View {
        AsyncImage(url: overrideURL ?? faviconURL, transaction: Transaction(animation: Theme.Animation.quick)) { phase in
            if case .success(let image) = phase {
                image
                    .resizable()
                    .scaledToFit()
                    .transition(.opacity)
            } else {
                Image(systemName: "globe")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(Theme.Colors.onSurfaceMuted)
                    .padding(2)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        .accessibilityHidden(true)
    }

    private var faviconURL: URL? {
        if let asset = Self.providerIcons[domain] {
            return URL(string: "https://openox.ai/assets/media/providers/\(asset)")
        }
        var components = URLComponents()
        components.scheme = "https"
        components.host = domain
        components.path = "/favicon.ico"
        return components.url
    }

    private static let providerIcons: [String: String] = [
        "aistudio.google.com": "gemini-5df7ba621e98.png",
        "bailian.console.aliyun.com": "qwen-2c0b5102f2f6.png",
        "chat.qwen.ai": "qwen-2c0b5102f2f6.png",
        "chatgpt.com": "openai-cc93fc236f95.png",
        "claude.ai": "claude-f33e82f43e42.png",
        "cloud.siliconflow.cn": "siliconflow-d14bca2f9d36.png",
        "console.anthropic.com": "anthropic-3650c4ab0d8b.png",
        "console.aws.amazon.com": "amazon-bedrock-054dd79d0d18.png",
        "console.byteplus.com": "byteplus-69123796ea61.png",
        "console.cloud.tencent.com": "tencent-c79af9f2e12d.png",
        "console.mistral.ai": "mistral-8cef2f7a7e64.png",
        "console.volcengine.com": "volcengine-b75350bc52f2.png",
        "console.x.ai": "xai-a2ce8b4f49e4.png",
        "github.com": "github-42f3fef4b9fa.png",
        "grok.com": "grok-55e9e35f69dc.png",
        "modelscope.cn": "modelscope-66ba2f389121.png",
        "modelstudio.console.alibabacloud.com": "qwen-2c0b5102f2f6.png",
        "open.bigmodel.cn": "bigmodel-075a7abbd239.png",
        "opencode.ai": "opencode-1b1339a3935c.png",
        "openrouter.ai": "openrouter-6a85b004492a.png",
        "platform.claude.com": "anthropic-3650c4ab0d8b.png",
        "platform.deepseek.com": "deepseek-63334309f4aa.png",
        "platform.kimi.ai": "kimi-610d65c0f97d.png",
        "platform.kimi.com": "kimi-610d65c0f97d.png",
        "platform.minimax.cn": "minimax-d98ca982c84d.png",
        "platform.minimax.io": "minimax-d98ca982c84d.png",
        "platform.minimaxi.com": "minimax-d98ca982c84d.png",
        "platform.moonshot.cn": "kimi-610d65c0f97d.png",
        "platform.openai.com": "openai-cc93fc236f95.png",
        "platform.stepfun.com": "stepfun-e641aa7e15df.png",
        "www.kimi.com": "kimi-610d65c0f97d.png",
        "z.ai": "zai-e74296ee999e.png",
    ]
}
