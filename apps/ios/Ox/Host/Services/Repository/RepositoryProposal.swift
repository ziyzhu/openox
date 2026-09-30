import CryptoKit
import Foundation

nonisolated struct RepositoryProposalContent: Sendable {
    struct Service: Sendable {
        let id: String
        let kind: Repository.ServiceKind
        let domain: String
        let files: [File]
    }

    struct SharedSkill: Sendable {
        let name: String
        let files: [File]
    }

    struct File: Sendable {
        let path: String
        let data: Data
    }

    let commitHash: String
    let services: [Service]
    let skills: [SharedSkill]
}

nonisolated struct RepositoryProposalRequest: Sendable {
    enum Status: String, Sendable {
        case draft
        case open
    }

    let target: RepositoryProposalTarget
    let title: String
    let body: String
    let status: Status
    let content: RepositoryProposalContent
}

nonisolated struct RepositoryProposalResult: Encodable, Sendable {
    let repository: String
    let provider: String
    let kind: String
    let identifier: String
    let url: String
    let status: String
    let baseRef: String
    let baseCommit: String
    let headRef: String
    let sourceCommitHash: String
    let publishedCommitHash: String
    let services: [String]
    let skills: [String]
    let operation: String
}

nonisolated struct RepositoryProposalTarget: Sendable {
    let url: String
    let owner: String
    let name: String
    let requestedBaseRef: String?
    let rootPath: String

    init(repository: String, baseRef: String?) throws {
        let repository = repository.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: repository),
              components.scheme == "https", components.host?.lowercased() == "github.com",
              components.user == nil, components.password == nil, components.port == nil,
              components.query == nil, components.fragment == nil else {
            throw RuntimeError.bridge("ox.repository.propose: repository must be an HTTPS GitHub repository URL")
        }
        let path = components.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard path.count == 2 else {
            throw RuntimeError.bridge("ox.repository.propose: repository must identify one GitHub owner and repository")
        }
        let owner = path[0]
        let name = path[1].hasSuffix(".git") ? String(path[1].dropLast(4)) : path[1]
        let validComponent = "^[A-Za-z0-9_.-]+$"
        guard !owner.isEmpty, !name.isEmpty,
              owner.range(of: validComponent, options: .regularExpression) != nil,
              name.range(of: validComponent, options: .regularExpression) != nil else {
            throw RuntimeError.bridge("ox.repository.propose: repository contains an invalid GitHub owner or repository name")
        }
        let base = baseRef?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let base, !Self.validBaseRef(base) {
            throw RuntimeError.bridge("ox.repository.propose: base must be a valid branch name")
        }
        self.url = "https://github.com/\(owner)/\(name)"
        self.owner = owner
        self.name = name
        self.requestedBaseRef = base
        self.rootPath = owner.lowercased() == "ziyzhu" && name.lowercased() == "openox" ? "repositories/builtin" : ""
    }

    func path(_ relativePath: String) -> String {
        rootPath.isEmpty ? relativePath : "\(rootPath)/\(relativePath)"
    }

    private static func validBaseRef(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 255,
              value.range(of: "^[A-Za-z0-9][A-Za-z0-9._/-]*$", options: .regularExpression) != nil,
              !value.contains(".."), !value.contains("//"), !value.contains("@{"),
              !value.hasSuffix("/"), !value.hasSuffix("."), !value.hasSuffix(".lock") else { return false }
        return value.split(separator: "/").allSatisfy { !$0.hasPrefix(".") && !$0.hasSuffix(".lock") }
    }
}

@MainActor
final class RepositoryProposal {
    static let shared = RepositoryProposal()

    private let github = GitHubRepositoryProposalProvider()

    func propose(
        _ request: RepositoryProposalRequest,
        authorization: RepositoryTokenPresenter?
    ) async throws -> RepositoryProposalResult {
        return try await github.propose(request, authorization: authorization)
    }
}

typealias RepositoryTokenValidation = @Sendable (_ token: String, _ displayName: String) async throws -> Void
typealias RepositoryTokenPresenter = @MainActor @Sendable (@escaping RepositoryTokenValidation) async -> Bool

nonisolated private final class GitHubRepositoryAccount: Sendable {
    struct Credential: Sendable {
        let accessToken: String
    }

    func credential(authorization: RepositoryTokenPresenter?) async throws -> Credential {
        if let token = Secret.publicationToken() {
            do {
                return try await validate(token)
            } catch GitHubRepositoryError.unauthorized {
                try Secret.clearPublicationToken()
            }
        }
        guard let authorization else {
            throw RuntimeError.bridge("Open this chat in the Ox app to enter a GitHub personal access token.")
        }
        let accepted = await authorization { token, displayName in
            _ = try await self.validate(token)
            try Task.checkCancellation()
            try Secret.savePublicationToken(token, displayName: displayName)
        }
        guard accepted, let token = Secret.publicationToken() else {
            try Task.checkCancellation()
            throw RuntimeError.bridge("GitHub token entry was cancelled.")
        }
        return try await validate(token)
    }

    private func validate(_ token: String) async throws -> Credential {
        let supportedPrefix = token.hasPrefix("ghp_") || token.hasPrefix("github_pat_")
        guard supportedPrefix, token.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }) else {
            throw GitHubRepositoryError.invalidToken
        }
        try await GitHubRepositoryAPI(accessToken: token).validateCredential()
        return Credential(accessToken: token)
    }
}

nonisolated private enum GitHubRepositoryError: LocalizedError {
    case invalidToken
    case unauthorized

    var errorDescription: String? {
        switch self {
        case .invalidToken: "Enter a GitHub personal access token beginning with ghp_ or github_pat_."
        case .unauthorized: "This GitHub token is invalid, expired, or revoked. Create a new token and try again."
        }
    }
}

nonisolated private final class GitHubRepositoryProposalProvider: @unchecked Sendable {
    private let account = GitHubRepositoryAccount()

    func propose(
        _ request: RepositoryProposalRequest,
        authorization: RepositoryTokenPresenter?
    ) async throws -> RepositoryProposalResult {
        let credential = try await account.credential(authorization: authorization)
        let api = GitHubRepositoryAPI(accessToken: credential.accessToken)
        let target = request.target
        let targetRepository = try await api.object(method: "GET", path: "/repos/\(target.owner)/\(target.name)")
        let canPush = ((targetRepository["permissions"] as? [String: Any])?["push"] as? Bool) == true
        guard canPush else {
            throw RuntimeError.bridge("The signed-in GitHub account cannot push a proposal to \(target.owner)/\(target.name). Ox does not create a fork.")
        }
        let baseRef = try target.requestedBaseRef ?? defaultBranch(targetRepository)
        let base = try await baseCommit(api: api, target: target, baseRef: baseRef)
        let files = try await proposalFiles(api: api, target: target, base: base, baseRef: baseRef, content: request.content)
        let branch = branchName(content: request.content)
        let publishedCommit = try await createCommit(
            api: api,
            target: target,
            base: base,
            branch: branch,
            title: request.title,
            files: files
        )
        let pullRequest = try await createOrUpdatePullRequest(
            api: api,
            target: target,
            baseRef: baseRef,
            branch: branch,
            request: request
        )
        guard let number = pullRequest.object["number"] as? NSNumber,
              let url = pullRequest.object["html_url"] as? String else {
            throw RuntimeError.bridge("GitHub returned an invalid pull request response.")
        }
        Log.service.info("RepositoryProposal completed provider=github repository=\(target.owner)/\(target.name) pull=\(number.intValue) services=\(request.content.services.count)")
        return RepositoryProposalResult(
            repository: target.url,
            provider: "github",
            kind: "pullRequest",
            identifier: String(number.intValue),
            url: url,
            status: request.status.rawValue,
            baseRef: baseRef,
            baseCommit: base.commit,
            headRef: branch,
            sourceCommitHash: request.content.commitHash,
            publishedCommitHash: publishedCommit,
            services: request.content.services.map(\.domain),
            skills: request.content.skills.map(\.name),
            operation: pullRequest.created ? "created" : "updated"
        )
    }

    private func defaultBranch(_ repository: [String: Any]) throws -> String {
        guard let branch = repository["default_branch"] as? String, !branch.isEmpty else {
            throw RuntimeError.bridge("GitHub did not return the target repository's default branch.")
        }
        return branch
    }

    private func baseCommit(
        api: GitHubRepositoryAPI,
        target: RepositoryProposalTarget,
        baseRef: String
    ) async throws -> (commit: String, tree: String) {
        let reference = try await api.object(method: "GET", path: "/repos/\(target.owner)/\(target.name)/git/ref/heads/\(baseRef)")
        guard let commit = (reference["object"] as? [String: Any])?["sha"] as? String else {
            throw RuntimeError.bridge("GitHub did not return the target branch head.")
        }
        let object = try await api.object(method: "GET", path: "/repos/\(target.owner)/\(target.name)/git/commits/\(commit)")
        guard let tree = (object["tree"] as? [String: Any])?["sha"] as? String else {
            throw RuntimeError.bridge("GitHub did not return the target Git tree.")
        }
        return (commit, tree)
    }

    private func proposalFiles(
        api: GitHubRepositoryAPI,
        target: RepositoryProposalTarget,
        base: (commit: String, tree: String),
        baseRef: String,
        content: RepositoryProposalContent
    ) async throws -> [String: Data?] {
        var files: [String: Data?] = [:]
        let serviceRoots = Set(content.services.map { target.path("\($0.kind.rawValue)/\($0.domain)") }
            + content.skills.map { target.path("skills/\($0.name)") })
        for file in content.services.flatMap(\.files) + content.skills.flatMap(\.files) {
            files[target.path(file.path)] = file.data
        }
        let tree = try await api.object(
            method: "GET",
            path: "/repos/\(target.owner)/\(target.name)/git/trees/\(base.tree)?recursive=1"
        )
        guard tree["truncated"] as? Bool != true, let entries = tree["tree"] as? [[String: Any]] else {
            throw RuntimeError.bridge("GitHub could not return the complete target tree.")
        }
        for entry in entries where entry["type"] as? String == "blob" {
            guard let path = entry["path"] as? String,
                  serviceRoots.contains(where: { path.hasPrefix($0 + "/") }) else { continue }
            if files[path] == nil { files[path] = .some(nil) }
        }
        let manifestPath = target.path("repository.json")
        let encodedBase = baseRef.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? baseRef
        let manifestResponse = try await api.object(
            method: "GET",
            path: "/repos/\(target.owner)/\(target.name)/contents/\(manifestPath)?ref=\(encodedBase)"
        )
        guard let encoded = manifestResponse["content"] as? String,
              let manifestData = Data(base64Encoded: encoded.filter { !$0.isWhitespace }),
              var manifest = try JSONSerialization.jsonObject(with: manifestData) as? [String: Any],
              manifest["version"] as? Int == 3,
              var services = manifest["services"] as? [String],
              let skills = manifest["skills"] as? [String] else {
            throw RuntimeError.bridge("The target repository manifest is invalid.")
        }
        services.append(contentsOf: content.services.map(\.id))
        manifest["services"] = Array(Set(services)).sorted()
        manifest["skills"] = Array(Set(skills + content.skills.map(\.name))).sorted()
        manifest.removeValue(forKey: "contentHash")
        var updatedManifest = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        updatedManifest.append(0x0A)
        files[manifestPath] = updatedManifest
        return files
    }

    private func createCommit(
        api: GitHubRepositoryAPI,
        target: RepositoryProposalTarget,
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
                    path: "/repos/\(target.owner)/\(target.name)/git/blobs",
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
            path: "/repos/\(target.owner)/\(target.name)/git/trees",
            body: ["base_tree": base.tree, "tree": entries]
        )
        guard let treeSHA = tree["sha"] as? String else {
            throw RuntimeError.bridge("GitHub did not return the proposal Git tree.")
        }
        let commit = try await api.object(
            method: "POST",
            path: "/repos/\(target.owner)/\(target.name)/git/commits",
            body: ["message": title, "tree": treeSHA, "parents": [base.commit]]
        )
        guard let commitSHA = commit["sha"] as? String else {
            throw RuntimeError.bridge("GitHub did not return the proposal commit.")
        }
        let refPath = "/repos/\(target.owner)/\(target.name)/git/refs/heads/\(branch)"
        if try await api.objectIfFound(path: refPath) != nil {
            _ = try await api.object(method: "PATCH", path: refPath, body: ["sha": commitSHA, "force": true])
        } else {
            _ = try await api.object(
                method: "POST",
                path: "/repos/\(target.owner)/\(target.name)/git/refs",
                body: ["ref": "refs/heads/\(branch)", "sha": commitSHA]
            )
        }
        return commitSHA
    }

    private func createOrUpdatePullRequest(
        api: GitHubRepositoryAPI,
        target: RepositoryProposalTarget,
        baseRef: String,
        branch: String,
        request: RepositoryProposalRequest
    ) async throws -> (object: [String: Any], created: Bool) {
        let head = "\(target.owner):\(branch)"
        let encodedHead = head.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? head
        let existing = try await api.array(
            method: "GET",
            path: "/repos/\(target.owner)/\(target.name)/pulls?state=open&head=\(encodedHead)"
        ).first
        if let existing, let number = existing["number"] as? NSNumber {
            let updated = try await api.object(
                method: "PATCH",
                path: "/repos/\(target.owner)/\(target.name)/pulls/\(number.intValue)",
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
            path: "/repos/\(target.owner)/\(target.name)/pulls",
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

    private func branchName(content: RepositoryProposalContent) -> String {
        let identity = (content.services.map(\.id) + content.skills.map { "skill:\($0.name)" }).sorted().joined(separator: "\n")
        let digest = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        return "ox/repository-\(content.commitHash.prefix(12))-\(digest.prefix(8))"
    }
}

nonisolated private struct GitHubRepositoryAPI: Sendable {
    private let accessToken: String
    private let root = URL(string: "https://api.github.com")!

    init(accessToken: String) {
        self.accessToken = accessToken
    }

    func validateCredential() async throws {
        _ = try await object(method: "GET", path: "/user")
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

    private func request(method: String, path: String, body: [String: Any]?, allowNotFound: Bool) async throws -> Any? {
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
            Log.network.error("RepositoryProposal GitHub method=\(method) path=\(url.path) status=\(status)")
            throw RuntimeError.bridge("GitHub returned HTTP \(status)\(message.map { ": \($0)" } ?? ".")")
        }
        return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }
}
