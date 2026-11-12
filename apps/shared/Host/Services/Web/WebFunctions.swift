import Foundation

nonisolated enum WebExecutionLimits {
    static let maxFetches = 8
    static let maxTransientAttachments = 4
    static let maxBytes = 20 * 1_024 * 1_024
}

extension Conversation {
    func runPage(_ url: URL) async -> String? {
        let purpose = L10n.string("Open website")
        let navigation: JSONValue = .object(["purpose": .string(purpose), "url": .string(url.absoluteString)])
        let source = """
        const page = await ox.web.browser.navigate(\(navigation.jsonString()));
        await ox.web.browser.showPage(\(JSONValue.object(["purpose": .string(purpose)]).jsonString()));
        return page;
        """
        let call = ToolCall(id: UUID().uuidString, name: ConversationTool.schema.name,
                            arguments: .object(["purpose": .string(purpose), "source": .string(source)]))
        Log.session.info("Conversation.runPage start id=\(id) host=\(url.host ?? "?")")
        await receiveAgentEvent(.runStarted(turnID: nil))
        await receiveAgentEvent(.generationStarted(model: model.id, turnID: nil))
        await receiveAgentEvent(.toolExecutionStart(toolCall: call))
        let result: ToolResultMessage
        do {
            let host = url.host(percentEncoded: false) ?? url.absoluteString
            let output = try await ConversationTool(conversation: self).execute(toolCallId: call.id, args: call.arguments) {
                Task.isCancelled ? nil : Self.pageFailureNote($0, host: host)
            }
            result = ToolResultMessage(toolCallId: call.id, toolName: call.name, content: output.content,
                                       diagnostics: output.diagnostics, isError: output.isError, truncated: output.truncated)
        } catch {
            result = ToolResultMessage(toolCallId: call.id, toolName: call.name,
                                       content: ToolResult(text: error.localizedDescription).content, isError: true)
        }
        await receiveAgentEvent(.toolExecutionEnd(toolCall: call, result: result))
        let stopped = Task.isCancelled
        var assistant = AssistantMessage(model: model.id, content: [.toolCall(call)])
        if stopped { assistant.stopReason = .aborted }
        await receiveAgentEvent(.generationFinished(message: assistant, toolResults: [result]))
        await receiveAgentEvent(.runFinished(ConversationRunResult(outcome: stopped ? .aborted : .completed)))
        let recorded = Array(turns.suffix(2))
        do {
            try await Task { try await recordDurableTurns(recorded) }.value
        } catch {
            Log.session.error("Conversation.runPage record failed id=\(id) error=\(error.localizedDescription)")
            return error.localizedDescription
        }
        Log.session.info("Conversation.runPage end id=\(id) navigated=\(!result.isError) stopped=\(stopped)")
        return nil
    }

    private static func pageFailureNote(_ failure: String, host: String) -> String {
        let line = failure.prefix { $0 != "\n" }
        let message = (try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)))?.objectValue?["message"]?.stringValue ?? String(line)
        if message.contains("requires an absolute public HTTPS URL") {
            return L10n.string("Couldn’t open \(host). Only HTTPS websites can be opened.")
        }
        let parts = message.components(separatedBy: "requested URL: ")
        let reason = parts.count == 2 ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
        guard !reason.isEmpty else { return L10n.string("Couldn’t open \(host).") }
        return L10n.string("Couldn’t open \(host). \(reason.hasSuffix(".") ? reason : reason + ".")")
    }

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
            if action == "getPageState" {
                let fields = arguments.objectValue ?? [:]
                var prepared: (Service, Service.ServiceWebPage)?
                if let domain = fields["service"]?.stringValue {
                    guard let target = self.attachedServices.first(where: { $0.domain == domain && $0.isWebService }),
                          let page = self.serviceOperations.loginPage(target) ?? (target.servicePages.count == 1 ? target.servicePages.first : nil) else {
                        throw RuntimeError.bridge("Attach the web service and prepare a unique live page before inspecting its frames.")
                    }
                    prepared = (target, page)
                }
                return try await self.serviceManager.browserActionSessions.session(for: service, ownerID: self.id)
                    .pageState(selector: fields["selector"]?.stringValue, frameID: fields["frameId"]?.stringValue,
                               prepared: prepared, attached: self.attachedServices,
                               authorizeSite: { site in try await self.nativeServiceOperations.authorizeBrowserSite(site, purpose) })
            }
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

    public func fetchWeb(url: String, options: JSONValue?, purpose: String) async throws -> JSONValue? {
        let fields: [String: JSONValue]
        switch options {
        case nil, .some(.null): fields = [:]
        case .some(.object(let value)): fields = value
        default: throw RuntimeError.bridge("ox.web.fetch: options must be an object")
        }
        let unknown = Set(fields.keys).subtracting(["maxBytes", "maxPages"])
        guard unknown.isEmpty else {
            throw RuntimeError.bridge("ox.web.fetch: unknown option '\(unknown.sorted().joined(separator: ", "))'")
        }
        let request = try WebFetchRequest(url: url)
        return try await tracked(Actions.webFetch, .object(["url": .string(request.url.absoluteString)]), purpose: purpose) {
            let (_, response) = try await fetchWebResource(request)
            let readOptions = FileLibrary.readOptions(from: options)
            if response.kind == .text || response.kind == .file || response.kind == .html {
                let maxBytes = min(max(readOptions.maxBytes ?? 65_536, 1), FileLimits.fileBytes)
                let feed = try await Task.detached(priority: .userInitiated) {
                    try WebFeed.parse(data: response.data, url: response.url, maxBytes: maxBytes)
                }.value
                if let feed {
                    var result = webFetchJSON(response, read: nil).objectValue ?? [:]
                    result["kind"] = .string("feed")
                    result["feed"] = feed.value
                    result["truncated"] = .bool(feed.truncated)
                    result["unsupported"] = .null
                    Log.webFetch.info("feed extraction result url=\(LogPrivacy.url(response.url.absoluteString)) bytes=\(response.data.count) truncated=\(feed.truncated)")
                    return .object(result)
                }
            }
            let read: FileLibrary.Read?
            switch response.kind {
            case .text, .html, .pdf:
                if response.kind == .html {
                    guard let html = String(data: response.data, encoding: .utf8) else {
                        throw WebFetchError.invalidText
                    }
                    let started = Date()
                    let markdown = try await Defuddle.markdown(html: html, baseURL: response.url)
                    let elapsed = Int(Date().timeIntervalSince(started) * 1_000)
                    Log.webFetch.info("native extraction result url=\(LogPrivacy.url(response.url.absoluteString)) htmlChars=\(html.count) markdownChars=\(markdown.count) ms=\(elapsed)")
                    read = try FileLibrary.read(
                        data: Data(markdown.utf8),
                        kind: .text,
                        options: readOptions
                    )
                } else {
                    read = try await Task.detached(priority: .userInitiated) {
                        try FileLibrary.read(data: response.data, kind: response.kind, options: readOptions)
                    }.value
                }
            case .image, .file:
                read = nil
            }
            let result = webFetchJSON(response, read: read)
            Log.session.info("bridge.web.fetch kind=\(response.kind.rawValue) text=\(read?.text?.count ?? 0) attached=false")
            return result
        }
    }

    func fetchWebResource(_ request: WebFetchRequest) async throws -> (Int, WebFetchResponse) {
        ensureExecutionContext()
        guard currentExecutionFetchCount < WebExecutionLimits.maxFetches else {
            throw RuntimeError.bridge("ox.web.fetch: one JavaScript execution may fetch at most eight resources")
        }
        let sequence = currentExecutionFetchCount
        currentExecutionFetchCount += 1
        let response = try await WebFetchClient.shared.fetch(request)
        let totalBytes = currentExecutionFetchBytes + response.data.count
        guard totalBytes <= WebExecutionLimits.maxBytes else { throw WebFetchError.executionTooLarge }
        currentExecutionFetchBytes = totalBytes
        return (sequence, response)
    }

    func appendTransientAttachment(_ attachment: TransientAttachment, sequence: Int? = nil) throws {
        guard currentExecutionTransientAttachments.count < WebExecutionLimits.maxTransientAttachments else { throw WebAttachmentError.tooMany }
        let totalBytes = currentExecutionTransientAttachments.reduce(attachment.data.count) { $0 + $1.attachment.data.count }
        guard totalBytes <= WebExecutionLimits.maxBytes else { throw WebAttachmentError.tooLarge }
        currentExecutionTransientAttachments.append((sequence ?? currentExecutionTransientAttachments.count, attachment))
    }

    private func webFetchJSON(
        _ response: WebFetchResponse,
        read: FileLibrary.Read?
    ) -> JSONValue {
        var fields = response.json().objectValue ?? [:]
        fields["kind"] = .string(response.kind.rawValue)
        fields["filename"] = .string(response.suggestedFilename)
        fields["bytes"] = .int(response.data.count)
        fields["text"] = read?.text.map(JSONValue.string) ?? .null
        fields["truncated"] = .bool(read?.truncated ?? false)
        fields["attached"] = .bool(false)
        fields["unsupported"] = read?.unsupported.map(JSONValue.string)
            ?? (read == nil || (response.kind == .pdf && read?.text?.isEmpty == true)
                ? .string("No readable text. Use ox.fs.attach with the returned url to explicitly send the original file to the model.") : .null)
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
