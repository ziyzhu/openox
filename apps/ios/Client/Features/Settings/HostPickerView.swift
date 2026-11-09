import SwiftUI
import UIKit

enum RemoteHostStatus: Equatable {
    case checking
    case reachable(name: String, version: String)
    case unreachable

    var subtitle: String {
        switch self {
        case .checking: L10n.string("Checking…")
        case .reachable(let name, let version): L10n.string("Reachable · \(name) \(version)")
        case .unreachable: L10n.string("Unavailable")
        }
    }
}

enum RemoteHostProbe {
    static let timeout: TimeInterval = 3
    private static let webSocketSchemes = ["ws": "ws", "wss": "wss", "http": "ws", "https": "wss"]

    static func status(of endpoint: URL) async -> RemoteHostStatus {
        let session = URLSession(configuration: .ephemeral)
        let task = session.webSocketTask(with: endpoint)
        defer {
            task.cancel(with: .goingAway, reason: nil)
            session.invalidateAndCancel()
        }
        task.resume()
        let id = UUID().uuidString
        let request: JSONValue = .object([
            "jsonrpc": .string("2.0"),
            "id": .string(id),
            "method": .string("host.describe"),
            "params": .object([:]),
        ])
        do {
            let (name, version) = try await withThrowingTaskGroup(of: (String, String).self) { group in
                group.addTask {
                    try await task.send(.data(await request.encoded()))
                    let message = try await task.receive()
                    let data: Data
                    switch message {
                    case .data(let value): data = value
                    case .string(let value): data = Data(value.utf8)
                    @unknown default: throw URLError(.cannotParseResponse)
                    }
                    let response = try await JSONValue.decode(data)
                    guard let fields = response.objectValue, fields["id"] == .string(id),
                          let implementation = fields["result"]?.objectValue?["implementation"]?.objectValue,
                          let name = implementation["name"]?.stringValue,
                          let version = implementation["version"]?.stringValue else {
                        throw URLError(.cannotParseResponse)
                    }
                    return (name, version)
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(timeout))
                    throw URLError(.timedOut)
                }
                defer { group.cancelAll() }
                guard let result = try await group.next() else { throw URLError(.cannotParseResponse) }
                return result
            }
            Log.app.info("RemoteHostProbe reachable name=\(name) version=\(version)")
            return .reachable(name: name, version: version)
        } catch {
            Log.app.info("RemoteHostProbe unavailable error=\(LogPrivacy.text(error.localizedDescription))")
            return .unreachable
        }
    }

    static func endpoint(from input: String) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let text = trimmed.contains("://") ? trimmed : "ws://\(trimmed)"
        guard var components = URLComponents(string: text),
              let scheme = components.scheme.flatMap({ webSocketSchemes[$0.lowercased()] }),
              let host = components.host, !host.isEmpty else { return nil }
        components.scheme = scheme
        if scheme == "ws", components.port == nil { components.port = Int(HostConfiguration.defaultPort) }
        if components.path == "/" { components.path = "" }
        return components.url
    }
}

struct HostPickerView: View {
    @Environment(HostAccess.self) private var access
    @State private var statuses: [URL: RemoteHostStatus] = [:]
    @State private var addingHost = false
    @State private var pendingRemoval: RemoteHost?

    static var localTitle: LocalizedStringKey {
        UIDevice.current.userInterfaceIdiom == .pad ? "This iPad" : "This iPhone"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SettingsLayout.sectionSpacing) {
                SettingsSection(
                    footer: "Ox uses the Host on this device by default. Add a remote Host by its Tailscale address, such as ws://my-mac.tailnet.ts.net:9876. Long-press a remote Host to remove it.",
                    layout: .group
                ) {
                    VStack(spacing: 0) {
                        Button { access.selection = .local } label: {
                            row(title: Text(Self.localTitle), subtitle: nil, selected: access.selection == .local)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier(A11yID.Settings.hostLocal)
                        .accessibilityValue(access.selection == .local ? L10n.string("Selected") : "")

                        ForEach(access.remoteHosts) { host in
                            Divider().settingsContentInset()
                            remoteRow(host)
                        }

                        Divider().settingsContentInset()

                        Button { addingHost = true } label: {
                            HStack(spacing: Theme.Spacing.xs) {
                                Image(systemName: "plus").foregroundStyle(Theme.Colors.primary)
                                Text("Add Remote Host")
                                    .font(Theme.Fonts.bodyMd)
                                    .foregroundStyle(Theme.Colors.primary)
                                Spacer(minLength: 0)
                            }
                            .settingsRowPadding()
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier(A11yID.Settings.hostAdd)
                    }
                }
            }
            .settingsPagePadding()
        }
        .scrollIndicators(.hidden)
        .background(Theme.Colors.background, ignoresSafeAreaEdges: .all)
        .navigationTitle("Ox Host")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await probeAll() }
        .task(id: access.remoteHosts.map(\.id)) { await probeAll() }
        .sheet(isPresented: $addingHost) {
            RemoteHostCreationSheet()
        }
        .confirmationDialog(
            "Remove this Host?",
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
            titleVisibility: .visible,
            presenting: pendingRemoval
        ) { host in
            Button("Remove", role: .destructive) {
                access.removeRemoteHost(host.endpoint)
                statuses[host.id] = nil
            }
            .accessibilityIdentifier(A11yID.Settings.hostRemoveConfirm)
            Button("Cancel", role: .cancel) {}
        } message: { host in
            Text(verbatim: host.endpoint.absoluteString)
        }
    }

    private func remoteRow(_ host: RemoteHost) -> some View {
        let selected = access.selection == .remote(endpoint: host.endpoint)
        let status = statuses[host.id] ?? .checking
        return Button { access.selection = .remote(endpoint: host.endpoint) } label: {
            row(
                title: Text(verbatim: host.name),
                subtitle: "\(status.subtitle) · \(host.endpoint.absoluteString)",
                selected: selected
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(role: .destructive) { pendingRemoval = host } label: {
                Label("Remove", systemImage: "trash")
            }
            .accessibilityIdentifier(A11yID.Settings.hostRemove(host.endpoint.absoluteString))
        }
        .accessibilityIdentifier(A11yID.Settings.hostRemote(host.endpoint.absoluteString))
        .accessibilityValue(selected ? L10n.string("Selected") : "")
        .accessibilityAction(named: Text("Remove")) { pendingRemoval = host }
    }

    private func row(title: Text, subtitle: String?, selected: Bool) -> some View {
        HStack(spacing: SettingsLayout.horizontalInset) {
            VStack(alignment: .leading, spacing: 2) {
                title
                    .font(Theme.Fonts.bodyMd)
                    .foregroundStyle(Theme.Colors.onSurface)
                if let subtitle {
                    Text(verbatim: subtitle)
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Theme.Colors.onSurfaceMuted)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: 0)
            if selected {
                Image(systemName: "checkmark")
                    .font(.system(.subheadline, weight: .semibold))
                    .foregroundStyle(Theme.Colors.primary)
            }
        }
        .padding(.horizontal, SettingsLayout.horizontalInset)
        .padding(.vertical, SettingsLayout.rowVerticalInset)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }

    private func probeAll() async {
        let hosts = access.remoteHosts
        for host in hosts { statuses[host.id] = .checking }
        await withTaskGroup(of: (URL, RemoteHostStatus).self) { group in
            for host in hosts {
                group.addTask { (host.id, await RemoteHostProbe.status(of: host.endpoint)) }
            }
            for await (id, status) in group { statuses[id] = status }
        }
    }
}

private struct RemoteHostCreationSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(HostAccess.self) private var access
    @State private var name = ""
    @State private var address = ""
    @State private var errorMessage: String?

    private var endpoint: URL? { RemoteHostProbe.endpoint(from: address) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: SettingsLayout.sectionSpacing) {
                    SettingsSection(
                        footer: "Use a ws://, wss://, or https:// address. ws:// uses port 9876 when none is given.",
                        layout: .group
                    ) {
                        VStack(alignment: .leading, spacing: 0) {
                            TextField("Name", text: $name)
                                .settingsRowPadding()
                                .accessibilityIdentifier(A11yID.Settings.hostAddName)
                            Divider().settingsContentInset()
                            TextField("ws://my-mac.tailnet.ts.net:9876", text: $address)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .keyboardType(.URL)
                                .settingsRowPadding()
                                .accessibilityIdentifier(A11yID.Settings.hostAddEndpoint)
                        }
                    }
                }
                .settingsPagePadding()
            }
            .background(Theme.Colors.background)
            .navigationTitle("Add Remote Host")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier(A11yID.Settings.hostAddCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { add() }
                        .disabled(endpoint == nil)
                        .accessibilityIdentifier(A11yID.Settings.hostAddConfirm)
                }
            }
            .alert("Couldn't Add Host", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
        }
    }

    private func add() {
        guard let endpoint else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let host = RemoteHost(name: trimmed.isEmpty ? endpoint.host() ?? endpoint.absoluteString : trimmed, endpoint: endpoint)
        guard access.addRemoteHost(host) else {
            errorMessage = L10n.string("This Host is already added, or the configuration couldn't be saved.")
            return
        }
        dismiss()
    }
}
