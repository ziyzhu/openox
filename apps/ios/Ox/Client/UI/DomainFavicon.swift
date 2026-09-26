import SwiftUI

struct DomainFavicon: View {
    let domain: String
    let size: CGFloat

    var body: some View {
        AsyncImage(url: faviconURL, transaction: Transaction(animation: Theme.Animation.quick)) { phase in
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
        switch domain {
        case "chat.qwen.ai":
            return URL(string: "https://assets.alicdn.com/g/qwenweb/qwen-chat-fe/0.2.91/favicon.png")
        case "grok.com":
            return URL(string: "https://grok.com/images/apple-touch-icon.png")
        case "aistudio.google.com":
            return URL(string: "https://www.gstatic.com/images/branding/productlogos/ai_studio/v1/web-64dp/logo_ai_studio_color_1x_web_64dp.png")
        default:
            break
        }
        var components = URLComponents()
        components.scheme = "https"
        components.host = domain
        components.path = "/favicon.ico"
        return components.url
    }
}
