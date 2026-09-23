import CryptoKit
import Foundation

nonisolated struct ServiceRepositoryProposalSnapshot: Sendable {
    struct Service: Sendable {
        let id: String
        let kind: ServiceRepository.ServiceKind
        let domain: String
        let files: [File]
    }

    struct File: Sendable {
        let path: String
        let data: Data
    }

    let commitHash: String
    let services: [Service]
}

nonisolated struct ServiceRepositoryProposalRequest: Sendable {
    enum Status: String, Sendable {
        case draft
        case open
    }

    let target: String
    let title: String
    let body: String
    let status: Status
    let snapshot: ServiceRepositoryProposalSnapshot
}

nonisolated struct ServiceRepositoryProposalResult: Encodable, Sendable {
    let target: String
    let provider: String
    let kind: String
    let identifier: String
    let url: String
    let status: String
    let baseRef: String
    let headRef: String
    let sourceCommitHash: String
    let publishedCommitHash: String
    let services: [String]
    let operation: String
}

@MainActor
final class ServiceRepositoryProposal {
    static let shared = ServiceRepositoryProposal()
    nonisolated static let targetID = "openox"

    private let github = GitHubServiceRepositoryProposalProvider()

    func propose(
        _ request: ServiceRepositoryProposalRequest,
        authorization: SubscriptionAuthorizationPresenter?
    ) async throws -> ServiceRepositoryProposalResult {
        guard request.target == Self.targetID else {
            throw RuntimeError.bridge("Unknown service publication target: \(request.target)")
        }
        return try await github.propose(request, authorization: authorization)
    }
}

nonisolated private final class GitHubServiceRepositoryAccount: @unchecked Sendable {
    struct Tokens: Codable, Sendable {
        let accessToken: String
        let login: String
    }

    private let store = SubscriptionTokenStore<Tokens>(key: "oauth:service-repository:github")

    func credential(authorization: SubscriptionAuthorizationPresenter?) async throws -> Tokens {
        if let current = store.current() { return current }
        guard let authorization else {
            throw RuntimeError.bridge("GitHub authorization UI is unavailable. Open this chat in the Ox app and try again.")
        }
        let generation = store.beginSignIn()
        let grant = try await GitHubRepositoryOAuth.requestDeviceGrant()
        let accepted = await authorization.device(grant.verificationURL, grant.userCode) {
            let tokens = try await GitHubRepositoryOAuth.poll(grant)
            return self.store.persist(tokens, expectedGeneration: generation)
        }
        guard accepted, let current = store.current() else {
            store.cancelSignIn(expectedGeneration: generation)
            throw RuntimeError.bridge("GitHub authorization was cancelled.")
        }
        return current
    }
}

nonisolated private struct GitHubRepositoryDeviceGrant: Sendable {
    let deviceCode: String
    let userCode: String
    let verificationURL: URL
    let interval: TimeInterval
    let expiresAt: Date
}

nonisolated private enum GitHubRepositoryOAuth {
    private static let deviceCodeURL = URL(string: "https://github.com/login/device/code")!
    private static let accessTokenURL = URL(string: "https://github.com/login/oauth/access_token")!

    static func requestDeviceGrant() async throws -> GitHubRepositoryDeviceGrant {
        let object = try await post(deviceCodeURL, body: [
            "client_id": GitHubCopilotOAuth.clientID,
            "scope": "public_repo",
        ])
        guard let deviceCode = object["device_code"] as? String,
              let userCode = object["user_code"] as? String,
              let verification = object["verification_uri"] as? String,
              let verificationURL = URL(string: verification)
        else { throw RuntimeError.bridge("GitHub returned an invalid authorization response.") }
        let interval = (object["interval"] as? NSNumber)?.doubleValue ?? 5
        let expiresIn = (object["expires_in"] as? NSNumber)?.doubleValue ?? 900
        return GitHubRepositoryDeviceGrant(
            deviceCode: deviceCode,
            userCode: userCode,
            verificationURL: verificationURL,
            interval: max(interval, 1),
            expiresAt: Date().addingTimeInterval(expiresIn)
        )
    }

    static func poll(_ grant: GitHubRepositoryDeviceGrant) async throws -> GitHubServiceRepositoryAccount.Tokens {
        var interval = grant.interval
        while Date() < grant.expiresAt {
            try Task.checkCancellation()
            let object = try await post(accessTokenURL, body: [
                "client_id": GitHubCopilotOAuth.clientID,
                "device_code": grant.deviceCode,
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
            ])
            if let accessToken = object["access_token"] as? String, !accessToken.isEmpty {
                let api = GitHubRepositoryAPI(accessToken: accessToken)
                let user = try await api.object(method: "GET", path: "/user")
                guard let login = user["login"] as? String, !login.isEmpty else {
                    throw RuntimeError.bridge("GitHub did not return the authorized account.")
                }
                return .init(accessToken: accessToken, login: login)
            }
            switch object["error"] as? String {
            case "authorization_pending": break
            case "slow_down": interval += 5
            case "access_denied": throw RuntimeError.bridge("GitHub authorization was denied.")
            case "expired_token": throw RuntimeError.bridge("GitHub authorization expired.")
            case let error?: throw RuntimeError.bridge("GitHub authorization failed: \(error)")
            case nil: break
            }
            try await Task.sleep(for: .seconds(interval))
        }
        throw RuntimeError.bridge("GitHub authorization expired.")
    }

    private static func post(_ url: URL, body: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Ox/iOS", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(status),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            Log.network.error("ServiceRepositoryProposal OAuth status=\(status)")
            throw RuntimeError.bridge("GitHub authorization returned HTTP \(status).")
        }
        return object
    }
}

nonisolated private final class GitHubServiceRepositoryProposalProvider: @unchecked Sendable {
    private let owner = "ziyzhu"
    private let repository = "openox"
    private let baseRef = "main"
    private let rootPath = "repositories/builtin"
    private let account = GitHubServiceRepositoryAccount()

    func propose(
        _ request: ServiceRepositoryProposalRequest,
        authorization: SubscriptionAuthorizationPresenter?
    ) async throws -> ServiceRepositoryProposalResult {
        let credential = try await account.credential(authorization: authorization)
        let api = GitHubRepositoryAPI(accessToken: credential.accessToken)
        let targetRepository = try await api.object(method: "GET", path: "/repos/\(owner)/\(repository)")
        let canPush = ((targetRepository["permissions"] as? [String: Any])?["push"] as? Bool) == true
        let publishingOwner = try await publishingOwner(api: api, login: credential.login, canPush: canPush)
        let base = try await baseCommit(api: api)
        let files = try await proposalFiles(api: api, base: base, snapshot: request.snapshot)
        let branch = branchName(snapshot: request.snapshot)
        let publishedCommit = try await createCommit(
            api: api,
            publishingOwner: publishingOwner,
            base: base,
            branch: branch,
            title: request.title,
            files: files
        )
        let pullRequest = try await createOrUpdatePullRequest(
            api: api,
            publishingOwner: publishingOwner,
            branch: branch,
            request: request
        )
        guard let number = pullRequest.object["number"] as? NSNumber,
              let url = pullRequest.object["html_url"] as? String else {
            throw RuntimeError.bridge("GitHub returned an invalid pull request response.")
        }
        Log.service.info("ServiceRepositoryProposal completed provider=github target=\(ServiceRepositoryProposal.targetID) pull=\(number.intValue) services=\(request.snapshot.services.count)")
        return ServiceRepositoryProposalResult(
            target: ServiceRepositoryProposal.targetID,
            provider: "github",
            kind: "pullRequest",
            identifier: String(number.intValue),
            url: url,
            status: request.status.rawValue,
            baseRef: baseRef,
            headRef: branch,
            sourceCommitHash: request.snapshot.commitHash,
            publishedCommitHash: publishedCommit,
            services: request.snapshot.services.map(\.domain),
            operation: pullRequest.created ? "created" : "updated"
        )
    }

    private func publishingOwner(api: GitHubRepositoryAPI, login: String, canPush: Bool) async throws -> String {
        if canPush { return owner }
        if let existing = try? await api.object(method: "GET", path: "/repos/\(login)/\(repository)"),
           existing["fork"] as? Bool == true,
           ((existing["parent"] as? [String: Any])?["full_name"] as? String)?.lowercased() == "\(owner)/\(repository)".lowercased() {
            return login
        }
        _ = try await api.object(method: "POST", path: "/repos/\(owner)/\(repository)/forks", body: [:])
        for _ in 0..<12 {
            try await Task.sleep(for: .seconds(2))
            if let fork = try? await api.object(method: "GET", path: "/repos/\(login)/\(repository)"),
               fork["fork"] as? Bool == true {
                return login
            }
        }
        throw RuntimeError.bridge("GitHub is still preparing the fork. Try again in a moment.")
    }

    private func baseCommit(api: GitHubRepositoryAPI) async throws -> (commit: String, tree: String) {
        let reference = try await api.object(method: "GET", path: "/repos/\(owner)/\(repository)/git/ref/heads/\(baseRef)")
        guard let commit = (reference["object"] as? [String: Any])?["sha"] as? String else {
            throw RuntimeError.bridge("GitHub did not return the target branch head.")
        }
        let object = try await api.object(method: "GET", path: "/repos/\(owner)/\(repository)/git/commits/\(commit)")
        guard let tree = (object["tree"] as? [String: Any])?["sha"] as? String else {
            throw RuntimeError.bridge("GitHub did not return the target Git tree.")
        }
        return (commit, tree)
    }

    private func proposalFiles(
        api: GitHubRepositoryAPI,
        base: (commit: String, tree: String),
        snapshot: ServiceRepositoryProposalSnapshot
    ) async throws -> [String: Data?] {
        var files: [String: Data?] = [:]
        let serviceRoots = Set(snapshot.services.map { "\(rootPath)/\($0.kind.rawValue)/\($0.domain)" })
        for service in snapshot.services {
            for file in service.files {
                files["\(rootPath)/\(file.path)"] = file.data
            }
        }
        let tree = try await api.object(
            method: "GET",
            path: "/repos/\(owner)/\(repository)/git/trees/\(base.tree)?recursive=1"
        )
        guard tree["truncated"] as? Bool != true, let entries = tree["tree"] as? [[String: Any]] else {
            throw RuntimeError.bridge("GitHub could not return the complete target tree.")
        }
        for path in entries.compactMap({ $0["path"] as? String }) where serviceRoots.contains(where: { path.hasPrefix($0 + "/") }) {
            if files[path] == nil { files[path] = .some(nil) }
        }
        let manifestPath = "\(rootPath)/repository.json"
        let manifestResponse = try await api.object(
            method: "GET",
            path: "/repos/\(owner)/\(repository)/contents/\(manifestPath)?ref=\(baseRef)"
        )
        guard let encoded = manifestResponse["content"] as? String,
              let manifestData = Data(base64Encoded: encoded.filter { !$0.isWhitespace }),
              var manifest = try JSONSerialization.jsonObject(with: manifestData) as? [String: Any],
              var services = manifest["services"] as? [String] else {
            throw RuntimeError.bridge("The target service repository manifest is invalid.")
        }
        services.append(contentsOf: snapshot.services.map(\.id))
        manifest["services"] = Array(Set(services)).sorted()
        var updatedManifest = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        updatedManifest.append(0x0A)
        files[manifestPath] = updatedManifest
        return files
    }

    private func createCommit(
        api: GitHubRepositoryAPI,
        publishingOwner: String,
        base: (commit: String, tree: String),
        branch: String,
        title: String,
        files: [String: Data?]
    ) async throws -> String {
        var entries: [[String: Any]] = []
        for path in files.keys.sorted() {
            guard let value = files[path] else { continue }
            if let data = value {
                let blob = try await api.object(
                    method: "POST",
                    path: "/repos/\(publishingOwner)/\(repository)/git/blobs",
                    body: ["content": data.base64EncodedString(), "encoding": "base64"]
                )
                guard let sha = blob["sha"] as? String else {
                    throw RuntimeError.bridge("GitHub did not return a Git blob identifier.")
                }
                entries.append(["path": path, "mode": "100644", "type": "blob", "sha": sha])
            } else {
                entries.append(["path": path, "mode": "100644", "type": "blob", "sha": NSNull()])
            }
        }
        let tree = try await api.object(
            method: "POST",
            path: "/repos/\(publishingOwner)/\(repository)/git/trees",
            body: ["base_tree": base.tree, "tree": entries]
        )
        guard let treeSHA = tree["sha"] as? String else {
            throw RuntimeError.bridge("GitHub did not return the proposal Git tree.")
        }
        let commit = try await api.object(
            method: "POST",
            path: "/repos/\(publishingOwner)/\(repository)/git/commits",
            body: ["message": title, "tree": treeSHA, "parents": [base.commit]]
        )
        guard let commitSHA = commit["sha"] as? String else {
            throw RuntimeError.bridge("GitHub did not return the proposal commit.")
        }
        let refPath = "/repos/\(publishingOwner)/\(repository)/git/refs/heads/\(branch)"
        if (try? await api.object(method: "GET", path: refPath)) != nil {
            _ = try await api.object(method: "PATCH", path: refPath, body: ["sha": commitSHA, "force": true])
        } else {
            _ = try await api.object(
                method: "POST",
                path: "/repos/\(publishingOwner)/\(repository)/git/refs",
                body: ["ref": "refs/heads/\(branch)", "sha": commitSHA]
            )
        }
        return commitSHA
    }

    private func createOrUpdatePullRequest(
        api: GitHubRepositoryAPI,
        publishingOwner: String,
        branch: String,
        request: ServiceRepositoryProposalRequest
    ) async throws -> (object: [String: Any], created: Bool) {
        let head = "\(publishingOwner):\(branch)"
        let encodedHead = head.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? head
        let existing = try await api.array(
            method: "GET",
            path: "/repos/\(owner)/\(repository)/pulls?state=open&head=\(encodedHead)"
        ).first
        if let existing, let number = existing["number"] as? NSNumber {
            let updated = try await api.object(
                method: "PATCH",
                path: "/repos/\(owner)/\(repository)/pulls/\(number.intValue)",
                body: ["title": request.title, "body": request.body, "base": baseRef]
            )
            let isDraft = updated["draft"] as? Bool == true
            guard isDraft == (request.status == .draft) else {
                throw RuntimeError.bridge("The existing pull request has a different draft status. Change it on GitHub and try again.")
            }
            return (updated, false)
        }
        let created = try await api.object(
            method: "POST",
            path: "/repos/\(owner)/\(repository)/pulls",
            body: [
                "title": request.title,
                "body": request.body,
                "head": head,
                "base": baseRef,
                "draft": request.status == .draft,
            ]
        )
        return (created, true)
    }

    private func branchName(snapshot: ServiceRepositoryProposalSnapshot) -> String {
        let identity = snapshot.services.map(\.id).sorted().joined(separator: "\n")
        let digest = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        return "ox/services-\(snapshot.commitHash.prefix(12))-\(digest.prefix(8))"
    }
}

nonisolated private struct GitHubRepositoryAPI: Sendable {
    private let accessToken: String
    private let root = URL(string: "https://api.github.com")!

    init(accessToken: String) {
        self.accessToken = accessToken
    }

    func object(method: String, path: String, body: [String: Any]? = nil) async throws -> [String: Any] {
        let value = try await request(method: method, path: path, body: body)
        guard let object = value as? [String: Any] else {
            throw RuntimeError.bridge("GitHub returned an unexpected response.")
        }
        return object
    }

    func array(method: String, path: String) async throws -> [[String: Any]] {
        let value = try await request(method: method, path: path, body: nil)
        guard let array = value as? [[String: Any]] else {
            throw RuntimeError.bridge("GitHub returned an unexpected response.")
        }
        return array
    }

    private func request(method: String, path: String, body: [String: Any]?) async throws -> Any {
        guard let url = URL(string: path, relativeTo: root)?.absoluteURL,
              url.host == root.host else { throw RuntimeError.bridge("GitHub request URL is invalid.") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Ox/iOS", forHTTPHeaderField: "User-Agent")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(status) else {
            let message = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["message"] as? String
            Log.network.error("ServiceRepositoryProposal GitHub method=\(method) path=\(url.path) status=\(status)")
            throw RuntimeError.bridge("GitHub returned HTTP \(status)\(message.map { ": \($0)" } ?? ".")")
        }
        return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }
}
