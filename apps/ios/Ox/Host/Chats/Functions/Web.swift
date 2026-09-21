import Foundation

extension Chat {
    public func browserOperation(action: String, arguments: JSONValue, purpose: String) async throws -> JSONValue? {
        guard let catalogAction = BrowserFunctionCatalog.action(id: action) else {
            throw RuntimeError.bridge("ox.web.browser: unknown action '\(action)'")
        }
        let service = serviceManager.browserService
        let name = catalogAction.name
        guard let definition = service.definition.action(action),
              let inputSchema = definition.inputSchema else {
            throw Service.InvokeError.unknown(name)
        }
        let violations = JSONSchemaValidator.validate(
            arguments,
            against: inputSchema,
            definitions: service.definition.definitions
        )
        guard violations.isEmpty else { throw Service.InvokeError.invalidInput(name, violations) }
        return try await tracked(name, arguments, purpose: purpose) {
            guard let implementation = service.iOSService else { throw Service.InvokeError.unknown(name) }
            let result = await implementation.invoke(
                service: service,
                actionID: action,
                args: arguments,
                purpose: purpose,
                approve: { _, _ in true },
                nativeInvocation: { [unowned self] _, id, args, purpose in
                    try await nativeServiceOperations.invoke(
                        service: service,
                        actionID: id,
                        args: args,
                        purpose: purpose
                    )
                }
            )
            return try result.get()
        }
    }

    public func searchWeb(query: String, purpose: String) async throws -> JSONValue? {
        let request = try WebSearchRequest(query: query)
        return try await tracked(Actions.webSearch, .object(["query": .string(request.query)]), purpose: purpose) {
            try await WebSearchEngine.shared.search(request).json
        }
    }

    public func fetchWeb(url: String, options: JSONValue?, purpose: String) async throws -> JSONValue? {
        let fields: [String: JSONValue]
        switch options {
        case nil, .some(.null): fields = [:]
        case .some(.object(let value)): fields = value
        default: throw RuntimeError.bridge("ox.web.fetch: options must be an object")
        }
        let unknown = Set(fields.keys).subtracting(["maxBytes"])
        guard unknown.isEmpty else {
            throw RuntimeError.bridge("ox.web.fetch: unknown option '\(unknown.sorted().joined(separator: ", "))'")
        }
        let request = try WebFetchRequest(url: url)
        return try await tracked(Actions.webFetch, .object(["url": .string(request.url.absoluteString)]), purpose: purpose) {
            let (sequence, response) = try await fetchWebResource(request)
            let attachment = try WebAttachmentFactory.make(response: response, filename: nil)
            let read: ArtifactLibrary.Read?
            let attached: Bool
            switch attachment.kind {
            case .text:
                let readOptions = ArtifactLibrary.readOptions(from: options)
                if response.kind == .html {
                    guard let html = String(data: response.data, encoding: .utf8) else {
                        throw WebFetchError.invalidText
                    }
                    let started = Date()
                    let markdown = try await Defuddle.markdown(html: html, baseURL: response.url)
                    let elapsed = Int(Date().timeIntervalSince(started) * 1_000)
                    Log.webFetch.info("native extraction result url=\(LogPrivacy.url(response.url.absoluteString)) htmlChars=\(html.count) markdownChars=\(markdown.count) ms=\(elapsed)")
                    read = try ArtifactLibrary.read(
                        data: Data(markdown.utf8),
                        kind: .text,
                        options: readOptions
                    )
                } else {
                    read = try await Task.detached(priority: .userInitiated) {
                        try ArtifactLibrary.read(data: response.data, kind: response.kind, options: readOptions)
                    }.value
                }
                attached = false
            case .image, .pdf:
                try appendTransientAttachment(attachment, sequence: sequence)
                read = nil
                attached = true
            case .file:
                read = nil
                attached = false
            }
            let result = webFetchJSON(response, attachment: attachment, read: read, attached: attached)
            Log.session.info("bridge.web.fetch kind=\(transientKind(attachment)) text=\(read?.text?.count ?? 0) attached=\(attached)")
            return result
        }
    }

    func fetchWebResource(_ request: WebFetchRequest) async throws -> (Int, WebFetchResponse) {
        ensureExecutionContext()
        guard currentExecutionFetchCount < 8 else {
            throw RuntimeError.bridge("ox.web.fetch: one JavaScript execution may fetch at most eight resources")
        }
        let sequence = currentExecutionFetchCount
        currentExecutionFetchCount += 1
        let response = try await WebFetchClient.shared.fetch(request)
        let totalBytes = currentExecutionFetchBytes + response.data.count
        guard totalBytes <= 20 * 1_024 * 1_024 else { throw WebFetchError.executionTooLarge }
        currentExecutionFetchBytes = totalBytes
        return (sequence, response)
    }

    func appendTransientAttachment(_ attachment: TransientAttachment, sequence: Int? = nil) throws {
        guard currentExecutionTransientAttachments.count < 4 else { throw WebAttachmentError.tooMany }
        let totalBytes = currentExecutionTransientAttachments.reduce(attachment.data.count) { $0 + $1.attachment.data.count }
        guard totalBytes <= 20 * 1_024 * 1_024 else { throw WebAttachmentError.tooLarge }
        currentExecutionTransientAttachments.append((sequence ?? currentExecutionTransientAttachments.count, attachment))
    }

    private func webFetchJSON(
        _ response: WebFetchResponse,
        attachment: TransientAttachment,
        read: ArtifactLibrary.Read?,
        attached: Bool
    ) -> JSONValue {
        var fields = response.json().objectValue ?? [:]
        fields["kind"] = .string(response.kind == .html ? "html" : transientKind(attachment))
        fields["filename"] = .string(attachment.displayName)
        fields["bytes"] = .int(response.data.count)
        fields["text"] = read?.text.map(JSONValue.string) ?? .null
        fields["truncated"] = .bool(read?.truncated ?? false)
        fields["attached"] = .bool(attached)
        fields["unsupported"] = read?.unsupported.map(JSONValue.string)
            ?? (attachment.kind == .file ? .string("This resource type can't be consumed by ox.web.fetch.") : .null)
        return .object(fields)
    }

    func attachmentJSON(_ attachment: TransientAttachment) -> JSONValue {
        return .object([
            "filename": .string(attachment.displayName),
            "contentType": .string(attachment.mimeType),
            "bytes": .int(attachment.data.count),
            "kind": .string(transientKind(attachment)),
        ])
    }

    private func transientKind(_ attachment: TransientAttachment) -> String {
        switch attachment.kind {
        case .image: "image"
        case .pdf: "pdf"
        case .text: "text"
        case .file: "file"
        }
    }
}
