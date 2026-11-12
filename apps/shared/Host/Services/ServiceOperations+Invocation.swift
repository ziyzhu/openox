import Foundation

extension ServiceOperations {
    func invokeAction(name: String, args: JSONValue?, session: JSONValue? = nil, pageURL: String? = nil, frameID: String? = nil, purpose: String) async throws -> JSONValue? {
        let (service, actionID) = try await resolveAction(name)
        return try await invokeAction(service: service, actionID: actionID, args: args, session: session, pageURL: pageURL, frameID: frameID, purpose: purpose)
    }

    func invokeAction(service: Service, actionID: String, args: JSONValue?, session: JSONValue? = nil, pageURL: String? = nil, frameID: String? = nil, purpose: String) async throws -> JSONValue? {
        guard !service.isMCPService || serviceManager.service(domain: service.domain) === service else {
            throw RuntimeError.bridge("This MCP connection changed or was removed. Attach the current service before invoking it.")
        }
        let hostStandard = !service.isWebService && service.definition.standardServiceActions.contains { $0.id == actionID }
        if service.isMCPService, !hostStandard, await service.loadManifest(reason: .invoke) == nil {
            throw RuntimeError.bridge("Service capabilities are unavailable; invoke the server's authorize action if authorization is required")
        }
        try service.definition.validateStandardServiceActions()
        var input = args ?? .object([:])
        if session != nil || pageURL != nil {
            guard service.isWebService, let baseURL = service.definition.baseURL else {
                throw RuntimeError.bridge("Session routing is supported only for web services")
            }
            _ = try service.executionURL(defaultURL: baseURL, session: session, pageURL: pageURL)
        }
        if frameID != nil, !service.isWebService || pageURL != nil {
            throw RuntimeError.bridge("frameId requires a web service and cannot be combined with pageUrl.")
        }
        let qualifiedName = service.definition.qualifiedActionName(actionID)
        guard let action = service.definition.action(actionID), let inputSchema = service.definition.inputSchema(for: action) else {
            throw Service.InvokeError.unknown(qualifiedName)
        }
        if service.isWebService, actionID == "search", service.definition.standardServiceActions.contains(where: { $0.id == actionID }),
           let schema = ModelGuidance.standardServiceActions.objectValue?["web"]?.arrayValue?.first(where: { $0.objectValue?["id"] == .string(actionID) })?.objectValue?["inputSchema"],
           let maximum = inputSchema.objectValue?["properties"]?.objectValue?["limit"]?.objectValue?["maximum"]?.intValue {
            let violations = JSONSchemaValidator.validate(input, against: schema, definitions: [:])
            guard violations.isEmpty else { throw Service.InvokeError.invalidInput(qualifiedName, violations) }
            var fields = input.objectValue ?? [:]
            fields["limit"] = .int(min(fields["limit"]?.intValue ?? 10, maximum))
            input = .object(fields)
        }
        let recordedInput: JSONValue = session == nil && pageURL == nil && frameID == nil ? input : .object([
            "input": input,
            "session": session ?? .null,
            "pageUrl": pageURL.map(JSONValue.string) ?? .null,
            "frameId": frameID.map(JSONValue.string) ?? .null,
        ])
        let prepared = try SecretAttempt.prepare(input)
        if !prepared.keys.isEmpty, hostStandard {
            throw RuntimeError.bridge("Secret references are not supported for this action")
        }
        input = prepared.args
        let inputViolations = JSONSchemaValidator.validate(
            input,
            against: inputSchema,
            definitions: service.definition.definitions,
            allowingSecretReferences: !prepared.keys.isEmpty
        )
        guard inputViolations.isEmpty else {
            throw Service.InvokeError.invalidInput(qualifiedName, inputViolations)
        }
        return try await recorded("ox.service.invoke(\(service.definition.qualifiedActionName(actionID)))", recordedInput, purpose: purpose) {
            if actionID != WebConversationContract.actionID || WebConversationContract.requiresApproval(input) {
                try await self.requireApproval(
                    action: qualifiedName,
                    defaultPolicy: action.defaultPolicy,
                    args: recordedInput.toAny(),
                    purpose: purpose
                )
            }
            if hostStandard {
                let value = try await self.invokeStandardServiceAction(service, actionID: actionID, purpose: purpose)
                let violations = JSONSchemaValidator.validate(value ?? .null, against: action.outputSchema ?? .null, definitions: [:])
                guard violations.isEmpty else { throw Service.InvokeError.invalidOutput(qualifiedName, violations) }
                return value
            }
            let isLogin = WebSessionContract.isEnabled(service.definition) && actionID == WebSessionContract.loginAction
            let chosenKey = isLogin && prepared.keys.isEmpty
                ? try await self.chooseSavedLogin(service: service, consumer: qualifiedName) : nil
            let selected = try chosenKey.map { key in
                try SecretAttempt.prepare(.object((input.objectValue ?? [:]).merging(
                    ["account": .object([SecretReference.marker: .string(key)])]) { $1 }))
            }
            let input = selected?.args ?? input
            let keys = selected?.keys ?? prepared.keys
            let secrets = keys.isEmpty ? nil : SecretAttempt(consumer: qualifiedName, keys: keys) { use, label in
                guard use.key != chosenKey else { return true }
                do {
                    try await self.requireApproval(
                        action: use.action,
                        defaultPolicy: .ask,
                        purpose: purpose,
                        prompt: L10n.string("Allow \(qualifiedName) to use the saved secret \(label)?\nOnly the service that owns it can read it, on its own domain. It never enters the conversation.")
                    )
                    return true
                } catch {
                    return false
                }
            }
            if let secrets, !isLogin, await !secrets.authorize() {
                throw OxFunctionError(code: "permission_denied", message: "\(qualifiedName): the user did not allow this action to use the saved secret.", recovery: "Stop. Do not retry with the same secret unless the user asks; offer manual login instead.")
            }
            let approve: @MainActor (String, Any?) async -> Bool = { name, args in
                guard service.isWebService,
                      name == service.definition.qualifiedActionName(WebSessionContract.listAction),
                      name != qualifiedName else { return true }
                do {
                    try await self.requireApproval(action: name, defaultPolicy: .allow, args: args, purpose: purpose)
                    return true
                } catch {
                    return false
                }
            }
            if let frameID {
                return try await self.invokeFrameAction(service: service, actionID: actionID, input: input,
                                                       frameID: frameID, session: session, secrets: secrets, purpose: purpose)
            }
            if let secrets, isLogin,
               await self.hasIntendedSession(service: service, secrets: secrets, approve: approve) {
                Log.service.info("Service.login automatic skipped domain=\(service.domain) reason=signed-in")
                return .object(["interaction": .string("automatic"), "authentication": .string("verified")])
            }
            if service.definition.supportsConversation, actionID == WebConversationContract.actionID {
                let attachments = try await resolveConversationAttachments(input.objectValue?["attachments"]?.arrayValue ?? [])
                return try await serviceManager.invokeConversation(service: service, args: input, owner: conversationOwner, attachments: attachments, session: session, pageURL: pageURL, approve: approve)
            }
            let result: Result<JSONValue, Error>
            if let implementation = service.apiService {
                result = await implementation.invoke(service: service, actionID: actionID, args: input, secrets: secrets, approve: approve)
            } else if let implementation = service.iOSService {
                let dispatched = try await secrets?.substitute(input, caller: service.definition.actionNamespace) ?? input
                result = await implementation.invoke(
                    service: service, actionID: actionID, args: dispatched, purpose: purpose,
                    approve: approve,
                    nativeInvocation: { _, id, args, purpose in
                        try await self.native.invoke(service: service, actionID: id, args: args, purpose: purpose)
                    }
                )
            } else if let implementation = service.remoteMCPService {
                let dispatched = try await secrets?.substitute(input, caller: service.definition.actionNamespace) ?? input
                result = await implementation.invoke(
                    service: service, actionID: actionID, args: dispatched,
                    approve: approve, readFile: { try await self.readMCPFile($0, purpose) }, receiveFiles: receiveFiles
                )
            } else if secrets != nil, isLogin {
                result = .success(.null)
            } else {
                result = await service.invokeAction(
                    actionID,
                    args: input,
                    session: session,
                    pageURL: pageURL,
                    secrets: secrets,
                    approve: approve
                )
            }
            let raw: JSONValue
            do { raw = try result.get() } catch {
                if isLogin, secrets == nil, self.redirectProvider(for: service) != nil {
                    return try await self.completeLogin(service: service, secrets: nil, input: input, session: session,
                                                        pageURL: pageURL, approve: approve)
                }
                secrets?.releaseRendering()
                throw error
            }
            let value = secrets?.redact(raw) ?? raw
            if isLogin {
                return try await self.completeLogin(service: service, secrets: secrets, input: input, session: session,
                                                    pageURL: pageURL, approve: approve)
            }
            secrets?.releaseRendering()
            return value
        }
    }

}
