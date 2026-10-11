import AppKit
import AuthenticationServices
import Network
import SwiftUI

@MainActor
enum OAuthWebLogin {
    static func present(authorizeURL: URL, redirectPrefix: String) async -> URL? {
        let flow = MacOAuthSession()
        return await withTaskCancellationHandler {
            await flow.run(authorizeURL: authorizeURL, redirectURI: redirectPrefix)
        } onCancel: {
            Task { @MainActor in flow.finish(nil) }
        }
    }

    static func presentDevice(authorizeURL: URL, userCode: String, poll: @escaping DeviceAuthorizationPoll) async -> Bool {
        let worker = Task { try await poll() }
        let owner = MacInteractionWindow(
            title: "Authorize account",
            size: NSSize(width: 540, height: 280),
            view: VStack(spacing: 16) {
                Text("Enter this code on the authorization page:").font(.headline)
                Text(userCode).font(.title).textSelection(.enabled)
                Text("Close this window to cancel.").foregroundStyle(.secondary)
            }.padding(24)
        ) { worker.cancel() }
        defer { owner.dismiss() }
        guard NSWorkspace.shared.open(authorizeURL) else { worker.cancel(); return false }
        return await withTaskCancellationHandler {
            do { return try await worker.value }
            catch {
                Log.network.error("MacOAuth.device failed error=\(error.localizedDescription)")
                return false
            }
        } onCancel: { worker.cancel() }
    }
}

@MainActor
private final class MacOAuthSession: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var owner: MacInteractionWindow?
    private var session: ASWebAuthenticationSession?
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var continuation: CheckedContinuation<URL?, Never>?
    private var timeout: Task<Void, Never>?

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        owner!.window
    }

    func run(authorizeURL: URL, redirectURI: String) async -> URL? {
        guard !Task.isCancelled, let redirect = URL(string: redirectURI) else { return nil }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            owner = MacInteractionWindow(
                title: "Sign in — Ox Host",
                size: NSSize(width: 540, height: 220),
                view: Text("Complete sign-in in your browser. Close this window to cancel.").padding(24)
            ) { [weak self] in self?.finish(nil) }
            timeout = Task {
                do { try await Task.sleep(for: .seconds(300)); finish(nil) }
                catch is CancellationError {}
                catch { finish(nil) }
            }
            if redirect.scheme == "http" {
                startLoopback(authorizeURL: authorizeURL, redirect: redirect)
            } else {
                let callback: ASWebAuthenticationSession.Callback
                if redirect.scheme == "https", let host = redirect.host { callback = .https(host: host, path: redirect.path) }
                else if let scheme = redirect.scheme { callback = .customScheme(scheme) }
                else { finish(nil); return }
                let session = ASWebAuthenticationSession(url: authorizeURL, callback: callback) { [weak self] url, _ in
                    Task { @MainActor in self?.finish(url) }
                }
                session.presentationContextProvider = self
                self.session = session
                if !session.start() { finish(nil) }
            }
        }
    }

    private func startLoopback(authorizeURL: URL, redirect: URL) {
        guard ["localhost", "127.0.0.1"].contains(redirect.host ?? ""),
              let number = redirect.port, let rawPort = UInt16(exactly: number), rawPort > 0,
              let port = NWEndpoint.Port(rawValue: rawPort) else { finish(nil); return }
        do {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: port)
            let listener = try NWListener(using: parameters)
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    switch state {
                    case .ready:
                        guard self?.continuation != nil else { return }
                        if !NSWorkspace.shared.open(authorizeURL) { self?.finish(nil) }
                    case .failed: self?.finish(nil)
                    default: break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in
                    guard let self, self.continuation != nil, self.connections.count < 8 else { connection.cancel(); return }
                    self.connections[ObjectIdentifier(connection)] = connection
                    connection.start(queue: .main)
                    self.receive(connection, redirect: redirect)
                }
            }
            self.listener = listener
            listener.start(queue: .main)
        } catch {
            Log.network.error("MacOAuth.listener failed error=\(error.localizedDescription)")
            finish(nil)
        }
    }

    private func receive(_ connection: NWConnection, redirect: URL, buffer: Data = Data()) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self else { connection.cancel(); return }
                guard self.continuation != nil, let data, error == nil else { self.close(connection); return }
                let received = buffer + data
                guard received.count <= 16 * 1024 else { self.close(connection); return }
                guard let text = String(data: received, encoding: .utf8), text.contains("\r\n\r\n") else {
                    if complete { self.close(connection) }
                    else { self.receive(connection, redirect: redirect, buffer: received) }
                    return
                }
                let url = self.callback(text, redirect: redirect)
                let body = url != nil ? "Return to Ox Host to continue." : "Invalid callback."
                let response = "HTTP/1.1 \(url != nil ? "200 OK" : "400 Bad Request")\r\nContent-Type: text/plain\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                connection.send(content: Data(response.utf8), completion: .contentProcessed { [weak self] _ in
                    Task { @MainActor in
                        self?.close(connection)
                        if let url { self?.finish(url) }
                    }
                })
            }
        }
    }

    private func close(_ connection: NWConnection) {
        connections.removeValue(forKey: ObjectIdentifier(connection))
        connection.cancel()
    }

    private func callback(_ request: String, redirect: URL) -> URL? {
        let parts = request.components(separatedBy: "\r\n")[0].split(separator: " ")
        guard parts.count == 3, parts[0] == "GET", parts[2] == "HTTP/1.1",
              let target = URLComponents(string: String(parts[1])),
              target.scheme == nil, target.host == nil, target.path == redirect.path else { return nil }
        var components = URLComponents(url: redirect, resolvingAgainstBaseURL: false)
        components?.query = target.query
        return components?.url
    }

    func finish(_ url: URL?) {
        guard let continuation else { return }
        self.continuation = nil
        timeout?.cancel()
        timeout = nil
        listener?.cancel()
        listener = nil
        for connection in Array(connections.values) { close(connection) }
        session?.cancel()
        session = nil
        owner?.dismiss()
        owner = nil
        continuation.resume(returning: url)
        Log.network.info("MacOAuth.finished captured=\(url != nil)")
    }
}
