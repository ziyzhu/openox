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
        authorization: RepositoryTokenPresenter?
    ) async throws -> ServiceRepositoryProposalResult {
        guard request.target == Self.targetID else {
            throw RuntimeError.bridge("Unknown service publication target: \(request.target)")
        }
        return try await github.propose(request, authorization: authorization)
    }
}

typealias RepositoryTokenValidation = @Sendable (String) async throws -> Void
typealias RepositoryTokenPresenter = @MainActor @Sendable (@escaping RepositoryTokenValidation) async -> Bool

nonisolated private final class GitHubServiceRepositoryAccount: Sendable {
    struct Tokens: Sendable {
        let accessToken: String
        let login: String
    }

    private let key = "pat:service-repository:github"

    func credential(authorization: RepositoryTokenPresenter?) async throws -> Tokens {
        if let token = Credentials.secret(for: key) {
            do {
                return try await validate(token)
            } catch GitHubRepositoryError.unauthorized {
                Credentials.clearSecret(for: key)
            } catch GitHubRepositoryError.missingScope {
                Credentials.clearSecret(for: key)
            }
        }
        guard let authorization else {
            throw RuntimeError.bridge("Open this chat in the Ox app to enter a GitHub personal access token.")
        }
        let accepted = await authorization { token in
            _ = try await self.validate(token)
            try Task.checkCancellation()
            try Credentials.setSecretChecked(token, for: self.key)
        }
        guard accepted, let token = Credentials.secret(for: key) else {
            try Task.checkCancellation()
            throw RuntimeError.bridge("GitHub token entry was cancelled.")
        }
        return try await validate(token)
    }

    private func validate(_ token: String) async throws -> Tokens {
        guard token.hasPrefix("ghp_"), token.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }) else {
            throw GitHubRepositoryError.invalidToken
        }
        let login = try await GitHubRepositoryAPI(accessToken: token).tokenLogin()
        return Tokens(accessToken: token, login: login)
    }
}

nonisolated private enum GitHubRepositoryError: LocalizedError {
    case invalidToken
    case unauthorized
    case missingScope

    var errorDescription: String? {
        switch self {
        case .invalidToken: "Enter a GitHub personal access token (classic), beginning with ghp_."
        case .unauthorized: "This GitHub token is invalid, expired, or revoked. Create a new token and try again."
        case .missingScope: "This GitHub token needs the public_repo scope to propose services."
        }
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
        authorization: RepositoryTokenPresenter?
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
        if let existing = try await api.objectIfFound(path: "/repos/\(login)/\(repository)"),
           existing["fork"] as? Bool == true,
           ((existing["parent"] as? [String: Any])?["full_name"] as? String)?.lowercased() == "\(owner)/\(repository)".lowercased() {
            return login
        }
        _ = try await api.object(method: "POST", path: "/repos/\(owner)/\(repository)/forks", body: [:])
        for _ in 0..<12 {
            try await Task.sleep(for: .seconds(2))
            if let fork = try await api.objectIfFound(path: "/repos/\(login)/\(repository)"),
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
        for entry in entries where entry["type"] as? String == "blob" {
            guard let path = entry["path"] as? String,
                  serviceRoots.contains(where: { path.hasPrefix($0 + "/") }) else { continue }
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
        if try await api.objectIfFound(path: refPath) != nil {
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

    func tokenLogin() async throws -> String {
        let value = try await request(method: "GET", path: "/user", body: nil, allowNotFound: false, validateScope: true)
        guard let object = value as? [String: Any], let login = object["login"] as? String, !login.isEmpty else {
            throw RuntimeError.bridge("GitHub did not return the token's account.")
        }
        return login
    }

    func object(method: String, path: String, body: [String: Any]? = nil) async throws -> [String: Any] {
        guard let value = try await request(method: method, path: path, body: body, allowNotFound: false) else {
            throw RuntimeError.bridge("GitHub resource was not found.")
        }
        guard let object = value as? [String: Any] else {
            throw RuntimeError.bridge("GitHub returned an unexpected response.")
        }
        return object
    }

    func objectIfFound(path: String) async throws -> [String: Any]? {
        guard let value = try await request(method: "GET", path: path, body: nil, allowNotFound: true) else { return nil }
        guard let object = value as? [String: Any] else {
            throw RuntimeError.bridge("GitHub returned an unexpected response.")
        }
        return object
    }

    func array(method: String, path: String) async throws -> [[String: Any]] {
        guard let value = try await request(method: method, path: path, body: nil, allowNotFound: false) else {
            throw RuntimeError.bridge("GitHub resource was not found.")
        }
        guard let array = value as? [[String: Any]] else {
            throw RuntimeError.bridge("GitHub returned an unexpected response.")
        }
        return array
    }

    private func request(method: String, path: String, body: [String: Any]?, allowNotFound: Bool, validateScope: Bool = false) async throws -> Any? {
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
        if status == 401 { throw GitHubRepositoryError.unauthorized }
        if allowNotFound && status == 404 { return nil }
        guard (200..<300).contains(status) else {
            let message = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["message"] as? String
            Log.network.error("ServiceRepositoryProposal GitHub method=\(method) path=\(url.path) status=\(status)")
            throw RuntimeError.bridge("GitHub returned HTTP \(status)\(message.map { ": \($0)" } ?? ".")")
        }
        if validateScope {
            let scopes = Set(((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "X-OAuth-Scopes") ?? "")
                .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
            guard scopes.contains("public_repo") || scopes.contains("repo") else { throw GitHubRepositoryError.missingScope }
        }
        return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }
}
