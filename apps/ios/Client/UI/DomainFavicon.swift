import SwiftUI
import UIKit

struct DomainFavicon: View {
    let domain: String
    let size: CGFloat
    var overrideURL: URL? = nil
    @Environment(\.localDomainArtwork) private var localArtwork

    var body: some View {
        Group {
            if let data = localArtwork[domain], let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
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
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        .accessibilityHidden(true)
    }

    private var faviconURL: URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = domain
        components.path = "/favicon.ico"
        return components.url
    }

}
