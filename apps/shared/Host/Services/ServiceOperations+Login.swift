import Foundation
import WebKit

extension ServiceOperations {
    func invokeLogin(service: Service, input: JSONValue, session: JSONValue?, pageURL: String?, secrets: SecretAttempt?,
                     approve: @escaping @MainActor (String, Any?) async -> Bool) async throws -> JSONValue {
        defer { secrets?.releaseRendering() }
        guard let action = await service.resolvedAction(WebSessionContract.loginAction, args: input, session: session,
                                                      pageURL: pageURL, scopeID: native.id) else { throw Service.EvalError.notReady }
        let page = try await service.openSessionPage(for: action)
        _ = try await serviceManager.actionScheduler.schedule(action, on: page, destination: action.baseURL) { $0 }
        for attempt in 0..<2 {
            let result = await service.invokeAction(WebSessionContract.loginAction, args: input, session: session, in: page,
                                                   secrets: secrets, scopeID: native.id, approve: approve)
            if let secrets, !secrets.awaitingApproval.isEmpty, attempt == 0 {
                guard await secrets.authorizePending() else { throw SecretAttemptError.denied }
                continue
            }
            _ = try result.get()
            break
        }
        let result = await loginResult(service: service, page: page)
        return secrets?.redact(result) ?? result
    }

    func loginResult(service: Service, page: BrowserSession) async -> JSONValue {
        var result: [String: JSONValue] = ["interaction": .string("automatic"), "authentication": .string("unverified")]
        for attempt in 0..<3 {
            do {
                try await page.waitForNavigationReady(timeout: 3)
                let generation = page.navigationGeneration
                let frames = try await page.discoverFrames()
                var document: JSONValue = .null
                if let host = page.page.url?.host, service.isServiceHost(host) {
                    let raw = try await service.evalOnce(page, BrowserPageState.script(selector: nil), timeout: 2)
                    let fields = raw.map(JSONValue.from)?.objectValue ?? [:]
                    document = .object([
                        "headings": .array(Array((fields["headings"]?.arrayValue ?? []).prefix(3))),
                        "messages": .array(Array((fields["messages"]?.arrayValue ?? []).prefix(3))),
                        "controls": .array(Array((fields["controls"]?.arrayValue ?? []).prefix(16)).map { control in
                            .object((control.objectValue ?? [:]).filter { ["type", "label", "disabled", "invalid"].contains($0.key) })
                        }),
                        "truncated": .bool(fields["truncated"] == .bool(true) || (fields["controls"]?.arrayValue?.count ?? 0) > 16
                            || (fields["headings"]?.arrayValue?.count ?? 0) > 3 || (fields["messages"]?.arrayValue?.count ?? 0) > 3),
                    ])
                }
                guard page.isOpen, page.navigationGeneration == generation, !page.page.isLoading else { throw Service.EvalError.contextInvalidated }
                result["page"] = .object([
                    "pageID": .string(page.id.uuidString),
                    "navigationGeneration": .int(generation),
                    "isLoading": .bool(page.page.isLoading),
                    "frames": page.frameMetadata(frames, services: serviceManager.services, attached: attachedDomains()),
                    "framesTruncated": .bool(page.omittedFrames > 0),
                    "document": document,
                ])
                break
            } catch Service.EvalError.contextInvalidated where attempt < 2 {
                continue
            } catch {
                Log.service.info("Service.login observation unavailable domain=\(service.domain) error=\(error.localizedDescription)")
                break
            }
        }
        return .object(result)
    }

    private func webLoginService(containing host: String) -> Service? {
        serviceManager.services.filter {
            $0.isWebService && WebSessionContract.isEnabled($0.definition)
                && SecretAttempt.host(host, isWithin: $0.definition.actionNamespace)
        }.max { $0.domain.count < $1.domain.count }
    }

    func offerToRemember(_ capture: LoginCapture, service: Service) async {
        guard let rememberSecret else { return }
        guard let captured = capture.credential() else {
            Log.service.info("Service.login remember skipped domain=\(service.domain) reason=nothing-captured")
            return
        }
        let owner = webLoginService(containing: captured.owner)?.definition.actionNamespace ?? "web:\(captured.owner)"
        guard !Secret.isNeverRemembered(owner) else {
            Log.service.info("Service.login remember skipped domain=\(service.domain) reason=never")
            return
        }
        let consumers = [service.definition.qualifiedActionName(WebSessionContract.loginAction)]
        let existing = (try? Secret.entries())?.first {
            $0.type == .account && $0.serviceID == owner && (try? Secret.fields(key: $0.key))?["username"] == captured.values["username"]
        }
        if let existing, (try? Secret.fields(key: existing.key)) == captured.values {
            consumers.forEach { try? Secret.setAccess(key: existing.key, consumer: $0, policy: .allow) }
            Log.service.info("Service.login remember skipped domain=\(service.domain) reason=unchanged")
            return
        }
        let key = existing?.key ?? "login.\(owner.split(separator: ":").last ?? "site").\(UUID().uuidString.prefix(8).lowercased())"
        let spec = SecretEntrySpec(key: key, type: .account, serviceID: owner, prefill: captured.values)
        guard await rememberSecret(spec) else {
            Log.service.info("Service.login remember declined domain=\(service.domain)")
            return
        }
        do {
            for consumer in consumers { try Secret.setAccess(key: key, consumer: consumer, policy: .allow) }
            Log.service.info("Service.login remember saved domain=\(service.domain) owner=\(owner) updated=\(existing != nil)")
        } catch {
            Log.service.error("Service.login remember access error=\(error.localizedDescription)")
        }
    }
}
