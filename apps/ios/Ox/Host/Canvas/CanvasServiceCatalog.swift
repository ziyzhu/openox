import Foundation

nonisolated enum CanvasServiceCatalog {
    private static let excluded: Set<String> = ["ox.service.attach", "ox.service.detach", "ox.service.listAttached"]

    static let schemas = OxFunctionCatalog.build().objectValue!.filter {
        $0.key.hasPrefix("ox.service.") && !excluded.contains($0.key)
    }

    static let help = OxFunctionCatalog.buildHelpText().objectValue!.filter { schemas[$0.key] != nil }

    static func validate(function: String, arguments: JSONValue) throws {
        guard let schema = schemas[function]?.objectValue?["inputSchema"] else {
            throw RuntimeError.bridge("Function unavailable in canvas: \(function)")
        }
        let violations = JSONSchemaValidator.validate(arguments, against: schema, definitions: [:])
        guard violations.isEmpty else {
            throw RuntimeError.bridge("\(function): \(Service.InvokeError.describe(violations))\n\nFull help:\n\(help[function]?.stringValue ?? "")")
        }
    }

    static func script(documentID: UUID) throws -> String {
        guard let url = Bundle.main.url(forResource: "CanvasSDK", withExtension: "js") else {
            throw RuntimeError.bridge("Canvas SDK unavailable")
        }
        let runtime = try String(contentsOf: url, encoding: .utf8)
        let catalog: JSONValue = .object(["schemas": .object(schemas), "help": .object(help)])
        let identity = JSONValue.string(documentID.uuidString).jsonString()
        return "\(runtime)\n(() => { const send = window.webkit.messageHandlers.oxCanvas.postMessage.bind(window.webkit.messageHandlers.oxCanvas); const ox = globalThis.__oxCreateCanvasSDK(\(catalog.jsonString()), args => send({ ...args, documentID: \(identity) })); delete globalThis.__oxCreateCanvasSDK; Object.defineProperty(globalThis, 'ox', { value: ox, writable: false, configurable: false }); })();"
    }
}

extension ServiceOperations {
    func call(function: String, arguments: JSONValue) async throws -> JSONValue? {
        try CanvasServiceCatalog.validate(function: function, arguments: arguments)
        let fields = arguments.objectValue ?? [:]
        let purpose = fields["purpose"]!.stringValue!
        switch function {
        case "ox.service.list":
            return try await listServices(kind: fields["kind"]?.stringValue, purpose: purpose)
        case "ox.service.find":
            return try await findServices(query: fields["query"]?.stringValue ?? "", purpose: purpose)
        case "ox.service.inspect":
            return try await inspectService(domain: fields["domain"]?.stringValue ?? "", actions: fields["actions"]?.arrayValue?.compactMap(\.stringValue), purpose: purpose)
        case "ox.service.validate":
            return try await validateService(domain: fields["domain"]?.stringValue ?? "", purpose: purpose)
        case "ox.service.invoke":
            return try await invokeAction(name: fields["name"]?.stringValue ?? "", args: fields["input"], purpose: purpose)
        case "ox.service.create":
            return try await createService(kind: fields["kind"]?.stringValue ?? "", domain: fields["domain"]?.stringValue ?? "", endpoint: fields["endpoint"]?.stringValue, transport: fields["transport"]?.stringValue, purpose: purpose)
        case "ox.service.update":
            return try await updateService(domain: fields["domain"]?.stringValue ?? "", endpoint: fields["endpoint"]?.stringValue, transport: fields["transport"]?.stringValue, purpose: purpose)
        case "ox.service.copy":
            return try await copyService(domain: fields["domain"]?.stringValue ?? "", purpose: purpose)
        case "ox.service.delete":
            return try await deleteService(domain: fields["domain"]?.stringValue ?? "", purpose: purpose)
        case "ox.repository.connect":
            return try await connectRepository(origin: fields["origin"]?.stringValue ?? "", purpose: purpose)
        case "ox.repository.sync":
            return try await syncRepository(repository: fields["repository"]?.stringValue ?? "", purpose: purpose)
        case "ox.repository.disconnect":
            return try await disconnectRepository(repository: fields["repository"]?.stringValue ?? "", purpose: purpose)
        case "ox.repository.propose":
            return try await proposeRepository(
                target: fields["target"]?.stringValue ?? "",
                commitHash: fields["commitHash"]?.stringValue ?? "",
                services: fields["services"]?.arrayValue?.compactMap(\.stringValue) ?? [],
                skills: fields["skills"]?.arrayValue?.compactMap(\.stringValue) ?? [],
                title: fields["title"]?.stringValue ?? "",
                body: fields["body"]?.stringValue ?? "",
                status: fields["status"]?.stringValue ?? "",
                purpose: purpose
            )
        case "ox.repository.git.status":
            return try await repositoryGitStatus(repository: fields["repository"]?.stringValue ?? "local", purpose: purpose)
        case "ox.repository.git.log":
            return try await repositoryGitLog(repository: fields["repository"]?.stringValue ?? "local", limit: fields["limit"]?.intValue ?? 20, cursor: fields["cursor"]?.stringValue, purpose: purpose)
        case "ox.repository.git.show":
            return try await repositoryGitShow(repository: fields["repository"]?.stringValue ?? "local", commitHash: fields["commitHash"]?.stringValue ?? "", path: fields["path"]?.stringValue, purpose: purpose)
        case "ox.repository.git.diff":
            return try await repositoryGitDiff(repository: fields["repository"]?.stringValue ?? "local", commitHash: fields["commitHash"]?.stringValue, baseCommitHash: fields["baseCommitHash"]?.stringValue, path: fields["path"]?.stringValue, purpose: purpose)
        case "ox.repository.git.checkout":
            return try await repositoryGitCheckout(repository: fields["repository"]?.stringValue ?? "local", commitHash: fields["commitHash"]?.stringValue ?? "", purpose: purpose)
        case "ox.repository.git.commit":
            return try await repositoryGitCommit(message: fields["message"]?.stringValue ?? "", purpose: purpose)
        case "ox.repository.git.revert":
            return try await repositoryGitRevert(commitHash: fields["commitHash"]?.stringValue ?? "", message: fields["message"]?.stringValue ?? "", purpose: purpose)
        case "ox.repository.git.restore":
            return try await repositoryGitRestore(path: fields["path"]?.stringValue, purpose: purpose)
        case "ox.service.signIn":
            return try await signInService(domain: fields["domain"]?.stringValue ?? "", purpose: purpose)
        case "ox.service.solve":
            return try await solveService(domain: fields["domain"]?.stringValue ?? "", args: fields["args"] ?? .object([:]), purpose: purpose)
        case "ox.service.pay":
            return try await payService(domain: fields["domain"]?.stringValue ?? "", args: fields["args"] ?? .object([:]), purpose: purpose)
        default: throw RuntimeError.bridge("Function unavailable in canvas: \(function)")
        }
    }
}
