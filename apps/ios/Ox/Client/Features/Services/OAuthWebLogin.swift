import UIKit
import SafariServices
import Network

// Drives an OAuth authorize flow whose client registers an http://localhost
// loopback redirect (the Codex CLI contract). Google blocks OAuth inside
// embedded WKWebViews ("disallowed_useragent"), so we render the authorize page
// in the system browser (SFSafariViewController, real Safari engine + shared
// session) and catch the loopback redirect with a tiny on-device HTTP listener
// bound to 127.0.0.1 — the same shape RFC 8252 native apps use.
@MainActor
enum OAuthWebLogin {
    static func present(authorizeURL: URL, redirectPrefix: String) async -> URL? {
        await withCheckedContinuation { (cont: CheckedContinuation<URL?, Never>) in
            let session = LoopbackOAuthSession(redirectPrefix: redirectPrefix)
            session.start(authorizeURL: authorizeURL) { cont.resume(returning: $0) }
        }
    }

    static func presentDevice(
        authorizeURL: URL,
        userCode: String,
        poll: @escaping DeviceAuthorizationPoll
    ) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let session = DeviceAuthorizationSession(userCode: userCode, poll: poll)
            session.start(authorizeURL: authorizeURL) { continuation.resume(returning: $0) }
        }
    }
}

@MainActor
private final class DeviceAuthorizationSession: NSObject, SFSafariViewControllerDelegate {
    private let userCode: String
    private let poll: DeviceAuthorizationPoll
    private var prompt: UIAlertController?
    private var safari: SFSafariViewController?
    private var task: Task<Void, Never>?
    private var onResult: ((Bool) -> Void)?
    private var retain: DeviceAuthorizationSession?

    init(userCode: String, poll: @escaping DeviceAuthorizationPoll) {
        self.userCode = userCode
        self.poll = poll
    }

    func start(authorizeURL: URL, onResult: @escaping (Bool) -> Void) {
        self.onResult = onResult
        retain = self
        guard let presenter = topViewController() else {
            finish(false)
            return
        }
        let prompt = UIAlertController(
            title: "Authorize GitHub Copilot",
            message: "Enter this code on GitHub:\n\n\(userCode)\n\nContinue will copy the code and open GitHub.",
            preferredStyle: .alert
        )
        prompt.addAction(UIAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in
            self?.finish(false)
        })
        prompt.addAction(UIAlertAction(title: "Copy & Continue", style: .default) { [weak self, weak prompt, weak presenter] _ in
            guard let self, let prompt, let presenter else {
                self?.finish(false)
                return
            }
            UIPasteboard.general.string = self.userCode
            prompt.dismiss(animated: true) {
                self.openSafari(authorizeURL, from: presenter)
            }
        })
        self.prompt = prompt
        presenter.present(prompt, animated: true)
    }

    private func openSafari(_ authorizeURL: URL, from presenter: UIViewController) {
        prompt = nil
        let safari = SFSafariViewController(url: authorizeURL)
        safari.delegate = self
        safari.modalPresentationStyle = .pageSheet
        self.safari = safari
        presenter.present(safari, animated: true)
        task = Task {
            do {
                finish(try await poll())
            } catch {
                Log.network.error("Device authorization failed: \(error.localizedDescription)")
                finish(false)
            }
        }
    }

    func safariViewControllerDidFinish(_ controller: SFSafariViewController) {
        finish(false)
    }

    private func finish(_ authorized: Bool) {
        guard let onResult else { return }
        self.onResult = nil
        task?.cancel()
        task = nil
        if let prompt, prompt.presentingViewController != nil {
            prompt.dismiss(animated: true)
        }
        self.prompt = nil
        if let safari, safari.presentingViewController != nil {
            safari.dismiss(animated: true)
        }
        self.safari = nil
        onResult(authorized)
        retain = nil
    }

    private func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        var top = scene?.keyWindow?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}

@MainActor
private final class LoopbackOAuthSession: NSObject, SFSafariViewControllerDelegate {
    private let listener: LoopbackRedirectListener?
    private var safari: SFSafariViewController?
    private var onResult: ((URL?) -> Void)?
    private var retain: LoopbackOAuthSession?

    init(redirectPrefix: String) {
        listener = LoopbackRedirectListener(redirectURI: redirectPrefix)
        super.init()
    }

    func start(authorizeURL: URL, onResult: @escaping (URL?) -> Void) {
        self.onResult = onResult
        retain = self

        guard let listener, let presenter = Self.topViewController() else {
            Log.ui.error("OAuthWebLogin: no listener/presenter")
            finish(nil)
            return
        }
        do {
            try listener.start { [weak self] url in
                Task { @MainActor in self?.finish(url) }
            }
        } catch {
            Log.ui.error("OAuthWebLogin: loopback listener failed: \(error.localizedDescription)")
            finish(nil)
            return
        }

        let safari = SFSafariViewController(url: authorizeURL)
        safari.delegate = self
        safari.modalPresentationStyle = .pageSheet
        self.safari = safari
        presenter.present(safari, animated: true)
    }

    func safariViewControllerDidFinish(_ controller: SFSafariViewController) {
        Log.ui.info("OAuthWebLogin: user dismissed Safari")
        finish(nil)
    }

    private func finish(_ url: URL?) {
        guard let onResult else { return }
        self.onResult = nil
        listener?.stop()
        if let safari, safari.presentingViewController != nil {
            safari.dismiss(animated: true)
        }
        safari = nil
        Log.ui.info("OAuthWebLogin: \(url == nil ? "cancelled" : "captured redirect")")
        onResult(url)
        retain = nil
    }

    private static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        var top = scene?.keyWindow?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}

// A single-shot HTTP listener on 127.0.0.1 that resolves with the first request
// hitting the registered callback path, then serves a "return to the app" page.
private final class LoopbackRedirectListener {
    private let port: NWEndpoint.Port
    private let base: URL
    private let callbackPath: String
    private let queue = DispatchQueue(label: "ai.openox.oauth.loopback")
    private var listener: NWListener?
    private var resultHandler: ((URL?) -> Void)?
    private var finished = false

    init?(redirectURI: String) {
        guard let comps = URLComponents(string: redirectURI),
              let portValue = comps.port,
              let port = NWEndpoint.Port(rawValue: UInt16(portValue)),
              let base = URL(string: "http://localhost:\(portValue)") else { return nil }
        self.port = port
        self.base = base
        callbackPath = comps.path
    }

    func start(onResult: @escaping (URL?) -> Void) throws {
        resultHandler = onResult
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: port)

        let listener = try NWListener(using: params)
        listener.newConnectionHandler = { [weak self] in self?.accept($0) }
        listener.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                Log.network.error("Loopback listener failed: \(error.localizedDescription)")
            }
        }
        self.listener = listener
        listener.start(queue: queue)
        Log.network.info("Loopback listener started on 127.0.0.1:\(port.rawValue)")
    }

    func stop() {
        queue.async { [weak self] in
            self?.listener?.cancel()
            self?.listener = nil
        }
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, _, _ in
            guard let self else { connection.cancel(); return }
            let target = data
                .flatMap { String(data: $0, encoding: .utf8) }
                .flatMap(Self.requestTarget)
            let callback = target
                .flatMap { URL(string: $0, relativeTo: self.base)?.absoluteURL }
                .flatMap { $0.path == self.callbackPath ? $0 : nil }
            self.servePage(over: connection)
            if let callback { self.complete(callback) }
        }
    }

    nonisolated private static func requestTarget(_ request: String) -> String? {
        guard let requestLine = request.split(separator: "\r\n", maxSplits: 1).first else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET" else { return nil }
        return String(parts[1])
    }

    private func servePage(over connection: NWConnection) {
        let body = Self.page
        let response = """
        HTTP/1.1 200 OK\r
        Content-Type: text/html; charset=utf-8\r
        Content-Length: \(body.utf8.count)\r
        Connection: close\r
        \r
        \(body)
        """
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
    }

    private func complete(_ url: URL?) {
        guard !finished else { return }
        finished = true
        let handler = resultHandler
        resultHandler = nil
        handler?(url)
    }

    private static var page: String {
        let title = L10n.string("Sign in")
        let body = L10n.string("Return to Ox to continue.")
        return """
        <!doctype html><html><head><meta charset="utf-8">\
        <meta name="viewport" content="width=device-width,initial-scale=1"><title>Ox</title></head>\
        <body style="font-family:-apple-system,system-ui,sans-serif;text-align:center;padding:3rem 1.5rem;color:#3a2a1a;background:#fff8ef">\
        <h2>\(title)</h2><p>\(body)</p></body></html>
        """
    }
}
