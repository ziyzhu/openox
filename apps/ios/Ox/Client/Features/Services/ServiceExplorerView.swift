import SwiftUI
import UIKit

struct RemoteMCPDetailRequest: Hashable {
    let id: String
    let endpoint: String
    let transport: RemoteMCPTransport?
    let name: String
    let description: String?

    init(endpoint: String) {
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        id = trimmed
        self.endpoint = trimmed
        transport = nil
        name = URL(string: trimmed)?.host ?? String(localized: "Connect remote MCP")
        description = trimmed
    }
}

enum ServiceExploreDestination: Hashable {
    case service(Service)
    case remoteMCP(RemoteMCPDetailRequest)
}

struct ServiceExplorePage: View {
    let onClose: () -> Void
    let ready: Bool
    let primaryAction: ServiceDetailPrimaryAction
    let browserSessionID: UUID?
    let isAttached: (Service) -> Bool
    let onSelect: (Service) -> Void
    @Environment(ServiceManager.self) private var serviceManager
    @State private var path: [ServiceExploreDestination] = []

    var body: some View {
        NavigationStack(path: $path) {
            ServiceExplorerView(
                services: serviceManager.services,
                onClose: onClose,
                ready: ready,
                onOpen: { path.append(.service($0)) },
                onConnectMCP: { path.append(.remoteMCP($0)) }
            )
                .navigationDestination(for: ServiceExploreDestination.self) { destination in
                    switch destination {
                    case .service(let service):
                        ServiceDetailView(
                            initialService: service,
                            primaryAction: primaryAction,
                            isAttached: isAttached(service),
                            onPrimaryAction: { onSelect(service) },
                            browserSessionID: browserSessionID
                        )
                        .toolbar(removing: .search)
                    case .remoteMCP(let request):
                        RemoteMCPDetailView(
                            request: request,
                            primaryAction: primaryAction,
                            isAttached: isAttached,
                            onPrimaryAction: onSelect
                        )
                        .toolbar(removing: .search)
                    }
                }
        }
    }
}

struct ServiceExplorerView: View {
    let services: [Service]
    let onClose: () -> Void
    let ready: Bool
    let onOpen: (Service) -> Void
    let onConnectMCP: (RemoteMCPDetailRequest) -> Void
    @Environment(ServiceManager.self) private var serviceManager

    private let pageSize = 20

    @State private var query = ""
    @State private var filter: ServiceManager.Filter = .all
    @State private var results: [ServiceManager.ServiceMatch] = []
    @State private var visible = 20
    @State private var searchPresented = false
    @State private var connectingMCP = false
    @State private var mcpEndpoint = ""

    private var shown: ArraySlice<ServiceManager.ServiceMatch> { matches.prefix(visible) }

    private var matches: [ServiceManager.ServiceMatch] {
        if filter == .all, trimmedQuery.isEmpty {
            return services.map {
                ServiceManager.ServiceMatch(service: $0, matchedActionID: nil, matchedAction: nil)
            }
        }
        return results
    }

    var body: some View {
        Group {
            if !ready {
                Color.clear
            } else if isLoadingServices {
                ContentLoadingView(label: "Loading services…")
            } else if let serviceLoadFailure {
                ContentUnavailableView {
                    Label("Couldn't load services", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(serviceLoadFailure)
                } actions: {
                    Button("Try Again", action: retryLoadingServices)
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.Colors.primary)
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if isRefreshingServices {
                            MonoRepositoryLoadingStatus(
                                accessibilityIdentifier: A11yID.Chat.Attach.servicesLoading
                            )
                        }
                        if filter == .mcp {
                            connectMCPRow
                        }
                        ForEach(shown) { match in
                            Button {
                                onOpen(match.service)
                            } label: {
                                row(match)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier(A11yID.Chat.Attach.service(match.service.domain))
                            .onAppear { extendIfNeeded(match) }
                        }
                    }
                    .padding(.horizontal, Theme.Spacing.lg)
                }
                .scrollIndicators(.hidden)
            }
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .background(Theme.Colors.background)
        .navigationTitle("Services")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                SheetDismissToolbarButton {
                    endSearch()
                    onClose()
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                filterMenu
            }
        }
        .searchable(text: $query, isPresented: $searchPresented, prompt: "Search services")
        .alert("Connect remote MCP", isPresented: $connectingMCP) {
            TextField("https://example.com/mcp", text: $mcpEndpoint)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier(A11yID.Chat.Attach.mcpEndpoint)
                .onAppear { styleMCPPlaceholder() }
            Button("Cancel", role: .cancel) {}
            Button("Connect") {
                let request = RemoteMCPDetailRequest(endpoint: mcpEndpoint)
                mcpEndpoint = ""
                onConnectMCP(request)
            }
        } message: {
            Text("Ox connects directly to the server and opens its sign-in page when needed. Credentials stay on this device.")
        }
        .task(id: searchKey) { await runSearch() }
    }

    private var isLoadingServices: Bool {
        guard services.isEmpty else { return false }
        if serviceManager.monoRepositoryState == .loading { return true }
        return switch serviceManager.repositoryState {
        case .idle, .syncing: true
        case .ready, .failed: false
        }
    }

    private var isRefreshingServices: Bool {
        !services.isEmpty && serviceManager.monoRepositoryState != .ready
    }

    private var serviceLoadFailure: String? {
        guard services.isEmpty, case .failed(let message) = serviceManager.repositoryState else { return nil }
        return message
    }

    private func retryLoadingServices() {
        let locale = AppLocale.shared.serviceLocale(for: AppRegion.shared.region)
        Task { await serviceManager.refreshServices(locale: locale) }
    }

    private func styleMCPPlaceholder() {
        DispatchQueue.main.async {
            let scene = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first { $0.activationState == .foregroundActive }
            var controller = scene?.windows.first(where: \.isKeyWindow)?.rootViewController
            while let presented = controller?.presentedViewController {
                controller = presented
            }
            guard let field = (controller as? UIAlertController)?.textFields?.first else { return }
            field.attributedPlaceholder = NSAttributedString(
                string: "https://example.com/mcp",
                attributes: [.foregroundColor: UIColor.placeholderText]
            )
        }
    }

    private var filterMenu: some View {
        Menu {
            Picker("Filter", selection: $filter) {
                ForEach(ServiceManager.Filter.allCases) { f in
                    Label(f.label, systemImage: f.systemImage).tag(f)
                }
            }
        } label: {
            Image(systemName: filter == .all ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                .foregroundStyle(Theme.Colors.onSurface)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .accessibilityIdentifier(A11yID.Chat.Attach.filter)
    }

    private var searchKey: String {
        query + "\u{1}" + filter.rawValue + "\u{1}" + String(serviceManager.monoRepositoryRevision)
    }

    private func runSearch() async {
        if filter == .all, trimmedQuery.isEmpty {
            results = []
            visible = pageSize
            return
        }
        if !query.trimmingCharacters(in: .whitespaces).isEmpty {
            try? await Task.sleep(for: .milliseconds(120))
            if Task.isCancelled { return }
        }
        let matches = await serviceManager.search(query, filter: filter)
        if Task.isCancelled { return }
        results = matches
        visible = pageSize
    }

    private func endSearch() {
        searchPresented = false
        query = ""
    }

    private func extendIfNeeded(_ match: ServiceManager.ServiceMatch) {
        guard match.id == shown.last?.id, visible < matches.count else { return }
        visible = min(visible + pageSize, matches.count)
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespaces)
    }

    private func ghostAvatar(icon: String) -> some View {
        RoundedRectangle(cornerRadius: Theme.Radius.md)
            .strokeBorder(
                Theme.Colors.onSurfaceMuted.opacity(0.5),
                style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])
            )
            .frame(width: 44, height: 44)
            .overlay {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(Theme.Colors.onSurfaceMuted)
            }
    }

    private var mcpAvatar: some View {
        Image("MCPFallback")
            .resizable()
            .scaledToFill()
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
    }

    private var connectMCPRow: some View {
        Button {
            endSearch()
            connectingMCP = true
        } label: {
            HStack(spacing: Theme.Spacing.md) {
                ghostAvatar(icon: "plus")
                VStack(alignment: .leading, spacing: 2) {
                    Text("Connect remote MCP")
                        .font(Theme.Fonts.bodyMd)
                        .foregroundStyle(Theme.Colors.onSurface)
                    Text("Add an MCP server by endpoint")
                        .font(Theme.Fonts.bodySm)
                        .foregroundStyle(Theme.Colors.onSurfaceMuted)
                        .lineLimit(1)
                }
                Spacer(minLength: Theme.Spacing.sm)
            }
            .padding(.vertical, Theme.Spacing.sm)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(A11yID.Chat.Attach.connectMCP)
    }

    private func row(_ match: ServiceManager.ServiceMatch) -> some View {
        let service = match.service
        let subtitle = match.matchedAction
            ?? (service.summary.isEmpty ? service.domain : service.summary)
        return HStack(spacing: Theme.Spacing.md) {
            ServiceAvatar(
                service: service,
                size: 44,
                shape: .roundedRect(Theme.Radius.md),
                monogramSize: 18
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(service.title)
                    .font(Theme.Fonts.bodyMd)
                    .foregroundStyle(Theme.Colors.onSurface)
                Text(subtitle)
                    .font(Theme.Fonts.bodySm)
                    .foregroundStyle(Theme.Colors.onSurfaceMuted)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, Theme.Spacing.sm)
        .contentShape(Rectangle())
    }
}

private struct RemoteMCPDetailView: View {
    private enum Phase {
        case connecting
        case connected(Service)
        case failed(String)
    }

    let request: RemoteMCPDetailRequest
    let primaryAction: ServiceDetailPrimaryAction
    let isAttached: (Service) -> Bool
    let onPrimaryAction: (Service) -> Void
    @Environment(ServiceManager.self) private var serviceManager
    @State private var phase: Phase = .connecting
    @State private var attempt = 0

    var body: some View {
        Group {
            switch phase {
            case .connecting:
                statusView(error: nil)
            case .connected(let service):
                ServiceDetailView(
                    initialService: service,
                    primaryAction: primaryAction,
                    isAttached: isAttached(service),
                    onPrimaryAction: { onPrimaryAction(service) }
                )
            case .failed(let error):
                statusView(error: error)
            }
        }
        .task(id: attempt) { await connect() }
    }

    private func statusView(error: String?) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                HStack(alignment: .top, spacing: Theme.Spacing.lg) {
                    RoundedRectangle(cornerRadius: Theme.Radius.lg)
                        .fill(Theme.Colors.surfaceSunken)
                        .frame(width: 64, height: 64)
                        .overlay {
                            Image(systemName: "network")
                                .font(Theme.Icons.lg)
                                .foregroundStyle(Theme.Colors.onSurfaceMuted)
                        }
                    VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                        Text(request.name)
                            .font(Theme.Fonts.headline)
                            .foregroundStyle(Theme.Colors.onSurface)
                        if error == nil {
                            HStack(spacing: Theme.Spacing.sm) {
                                CellularAutomatonLoader.small
                                Text("Connecting…")
                            }
                            .font(Theme.Fonts.labelMd)
                            .foregroundStyle(Theme.Colors.onSurfaceMuted)
                        } else {
                            Text("Couldn't connect MCP")
                                .font(Theme.Fonts.labelMd)
                                .foregroundStyle(Theme.Colors.error.dynamic)
                        }
                    }
                }
                if let description = request.description {
                    Text(description)
                        .font(Theme.Fonts.bodyMd)
                        .foregroundStyle(Theme.Colors.onSurfaceMuted)
                }
                if let error {
                    Text(error)
                        .font(Theme.Fonts.bodyMd)
                        .foregroundStyle(Theme.Colors.onSurface)
                    Button("Try Again") {
                        phase = .connecting
                        attempt += 1
                    }
                    .buttonStyle(OxChipButton(filled: true))
                    .accessibilityIdentifier(A11yID.Chat.Attach.retryMCP(request.id))
                }
            }
            .padding(.horizontal, Theme.Spacing.lg)
            .padding(.vertical, Theme.Spacing.lg)
        }
        .background(Theme.Colors.background)
        .navigationTitle(request.name)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier(A11yID.Chat.Attach.mcpConnecting(request.id))
    }

    private func connect() async {
        guard case .connecting = phase else { return }
        do {
            let service = try await serviceManager.connectRemoteMCP(
                request.endpoint,
                transport: request.transport
            )
            guard !Task.isCancelled else { return }
            phase = .connected(service)
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled else { return }
            phase = .failed(error.localizedDescription)
        }
    }
}

private extension ServiceManager.Filter {
    var label: LocalizedStringKey {
        switch self {
        case .all: return "All"
        case .web: return "Web"
        case .local: return "Local"
        case .iOS: return "iOS"
        case .mcp: return "MCP"
        case .saved: return "Saved"
        }
    }

    var systemImage: String {
        switch self {
        case .all: return "square.grid.2x2"
        case .web: return "globe"
        case .local: return "folder"
        case .iOS: return "iphone"
        case .mcp: return "point.3.connected.trianglepath.dotted"
        case .saved: return "bookmark"
        }
    }
}
