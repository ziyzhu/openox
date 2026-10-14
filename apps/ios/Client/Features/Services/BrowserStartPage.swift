import SwiftUI

struct BrowserStartPage: View {
    let open: (URL) -> Void
    @Environment(ServiceManager.self) private var serviceManager
    @ScaledMetric(relativeTo: .caption) private var tileWidth: CGFloat = 76

    private var websites: [(service: Service, url: URL)] {
        let saved = serviceManager.savedDomains
        return serviceManager.services
            .compactMap { service in
                guard service.webService != nil, let url = service.definition.baseURL else { return nil }
                return (service, url)
            }
            .sorted { lhs, rhs in
                let lhsSaved = saved.contains(lhs.service.domain)
                if lhsSaved != saved.contains(rhs.service.domain) { return lhsSaved }
                let lhsRank = ServiceListOrder.rank(lhs.service.domain)
                let rhsRank = ServiceListOrder.rank(rhs.service.domain)
                if lhsRank != rhsRank { return lhsRank < rhsRank }
                return lhs.service.title.localizedCaseInsensitiveCompare(rhs.service.title) == .orderedAscending
            }
    }

    var body: some View {
        let websites = websites
        Group {
            if websites.isEmpty {
                ContentUnavailableView {
                    Label("No Websites", systemImage: "globe")
                } description: {
                    Text("Enter a website address below.")
                }
                .accessibilityIdentifier(A11yID.ServiceBrowser.startPageEmpty)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: tileWidth), spacing: Theme.Spacing.md, alignment: .top)], spacing: Theme.Spacing.lg) {
                        ForEach(websites, id: \.service.domain) { website in
                            tile(website.service, url: website.url)
                        }
                    }
                    .frame(maxWidth: Theme.ContainerWidth.readable)
                    .padding(.horizontal, 20)
                    .padding(.top, Theme.Spacing.xs)
                    .padding(.bottom, Theme.Spacing.lg)
                    .frame(maxWidth: .infinity)
                }
                .scrollDismissesKeyboard(.immediately)
                .scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
                .accessibilityIdentifier(A11yID.ServiceBrowser.startPage)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Colors.surface)
    }

    private func tile(_ service: Service, url: URL) -> some View {
        Button { open(url) } label: {
            VStack(spacing: Theme.Spacing.xs) {
                ServiceAvatar(service: service, size: 56, shape: .roundedRect(Theme.Radius.md))
                Text(service.title)
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.Colors.onSurface)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(service.title)
        .accessibilityValue(url.host(percentEncoded: false) ?? "")
        .accessibilityIdentifier(A11yID.ServiceBrowser.startPageService(service.domain))
    }
}
