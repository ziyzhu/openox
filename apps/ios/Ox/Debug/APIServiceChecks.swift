#if targetEnvironment(simulator)
import Foundation
import Synchronization

nonisolated final class APIServiceFixtureProtocol: URLProtocol, @unchecked Sendable {
    static let requests = Mutex<[URLRequest]>([])

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        Self.requests.withLock { $0.append(request) }
        guard let url = request.url, url.host == "api-fixture.invalid" else {
            client?.urlProtocol(self, didFailWithError: APIServiceError.destinationDenied)
            return
        }
        let status = url.path == "/revoked-token" ? 400 : url.path == "/failed-token" ? 500
            : url.path.hasSuffix("unauthorized") ? 401 : url.path.hasSuffix("redirect") ? 302 : 200
        let body = url.path == "/revoked-token" ? #"{"error":"invalid_grant"}"# : url.path == "/token"
            ? #"{"access_token":"fixture-access","token_type":"Bearer","refresh_token":"fixture-rotated","expires_in":3600,"scope":"read"}"#
            : #"{"items":[{"id":"fixture-item"}],"nextCursor":null}"#
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json", "Location": "https://outside.invalid/"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

@MainActor
enum APIServiceChecks {
    static func run(manager: ServiceManager) async -> JSONValue {
        APIServiceHTTP.fixtureProtocol = APIServiceFixtureProtocol.self
        APIServiceFixtureProtocol.requests.withLock { $0.removeAll() }
        defer { APIServiceHTTP.fixtureProtocol = nil }
        var checks: [String: JSONValue] = [:]
        let fixtureID = "api-check-" + UUID().uuidString.lowercased()
        let oauth: JSONValue = .object([
            "type": .string("oauth2"), "flow": .string("authorizationCode"),
            "authorizationURL": .string("https://api-fixture.invalid/authorize"),
            "tokenURL": .string("https://api-fixture.invalid/token"), "clientID": .string("fixture-client"),
            "redirectURI": .string("ai.openox.fixture:/callback"), "scopes": .array([.string("read")]), "pkce": .string("S256"),
        ])
        do {
            for (name, auth) in [
                ("none", JSONValue.object(["type": .string("none")])),
                ("header", .object(["type": .string("apiKey"), "in": .string("header"), "name": .string("X-API-Key")])),
                ("query", .object(["type": .string("apiKey"), "in": .string("query"), "name": .string("key")])),
                ("basic", .object(["type": .string("http"), "scheme": .string("basic")])),
                ("bearer", .object(["type": .string("http"), "scheme": .string("bearer")])),
            ] {
                let definition = try definition(fixtureID + "-" + name, auth: auth)
                let service = try APIService(definition: definition)
                defer { service.authorization.clear() }
                try service.authorization.save(APIServiceCredential(binding: service.authorization.binding,
                    secret: "fixture-secret", username: "fixture-user"))
                let value = try await service.request(.object(["path": .string("items")]), authenticated: true, allowsMutation: false)
                let request = APIServiceFixtureProtocol.requests.withLock { $0.last! }
                let valid: Bool
                switch name {
                case "header": valid = request.value(forHTTPHeaderField: "X-API-Key") == "fixture-secret"
                case "query": valid = OAuthSupport.queryValue("key", in: request.url!) == "fixture-secret"
                case "basic": valid = request.value(forHTTPHeaderField: "Authorization") == "Basic " + Data("fixture-user:fixture-secret".utf8).base64EncodedString()
                case "bearer": valid = request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-secret"
                default: valid = request.value(forHTTPHeaderField: "Authorization") == nil
                }
                checks[name] = .bool(valid && value.objectValue?["items"]?.arrayValue?.count == 1)
                let restored = try APIServiceAuthorization(definition: definition)
                checks["restore-" + name] = .bool(restored.credential?.secret == "fixture-secret")
                var changed = definition.manifest.objectValue!
                changed["baseUrl"] = .string("https://outside.invalid/v1/")
                let replacement = try APIServiceAuthorization(definition: ServiceDefinition(manifest: .object(changed)))
                checks["binding-" + name] = .bool(replacement.credential == nil)
            }
            let service = try APIService(definition: definition(fixtureID, auth: oauth))
            defer { service.authorization.clear() }
            try service.authorization.save(APIServiceCredential(binding: service.authorization.binding,
                secret: "fixture-expired", refreshToken: "fixture-refresh", expiresAt: .distantPast, scopes: ["read"]))
            let request: JSONValue = .object(["path": .string("items")])
            let secondInstance = try APIService(definition: definition(fixtureID, auth: oauth))
            async let first = service.request(request, authenticated: true, allowsMutation: false)
            async let second = secondInstance.request(request, authenticated: true, allowsMutation: false)
            _ = try await (first, second)
            let refreshCount = APIServiceFixtureProtocol.requests.withLock { $0.filter { $0.url?.path == "/token" }.count }
            checks["single-refresh"] = .bool(refreshCount == 1)
            checks["rotated-refresh-token"] = .bool(service.authorization.credential?.refreshToken == "fixture-rotated")
            for endpoint in ["revoked-token", "failed-token"] {
                var configuration = oauth.objectValue!
                configuration["tokenURL"] = .string("https://api-fixture.invalid/" + endpoint)
                let authorization = try APIServiceAuthorization(definition: definition(fixtureID + endpoint, auth: .object(configuration)))
                defer { authorization.clear() }
                try authorization.save(APIServiceCredential(binding: authorization.binding, secret: "fixture-expired",
                    refreshToken: "fixture-refresh", expiresAt: .distantPast, scopes: ["read"]))
                if endpoint == "revoked-token" {
                    let access = try await authorization.checkAccess(previous: nil)
                    checks["revoked-refresh-clears-credentials"] = .bool(access.isSignedOut && authorization.credential == nil)
                } else {
                    do {
                        _ = try await authorization.checkAccess(previous: nil)
                        checks["failed-refresh-preserves-credentials"] = .bool(false)
                    } catch {
                        checks["failed-refresh-preserves-credentials"] = .bool(authorization.credential?.refreshToken == "fixture-refresh")
                    }
                }
            }
            for (name, args, mutation) in [
                ("foreign-origin", JSONValue.object(["path": .string("https://outside.invalid/v1/items")]), false),
                ("path-escape", .object(["path": .string("../items")]), false),
                ("encoded-path-escape", .object(["path": .string("%2e%2e/items")]), false),
                ("encoded-separator-escape", .object(["path": .string("/v1/%2f..%2fitems")]), false),
                ("mutation-gate", .object(["path": .string("items"), "method": .string("POST")]), false),
                ("redirect-denied", .object(["path": .string("redirect")]), false),
                ("http-error", .object(["path": .string("unauthorized")]), false),
            ] {
                let before = APIServiceFixtureProtocol.requests.withLock { $0.count }
                do {
                    _ = try await service.request(args, authenticated: true, allowsMutation: mutation)
                    checks[name] = .bool(false)
                } catch {
                    let expectedRequests = ["http-error", "redirect-denied"].contains(name) ? 1 : 0
                    checks[name] = .bool(APIServiceFixtureProtocol.requests.withLock { $0.count } == before + expectedRequests)
                }
            }
            let rejected = try await service.authorization.checkAccess(previous: nil)
            checks["rejected-credential"] = .bool(rejected.isSignedOut)
            try service.authorization.save(APIServiceCredential(binding: service.authorization.binding,
                secret: "fixture-access", refreshToken: "fixture-rotated", expiresAt: .distantFuture, scopes: ["read"]))
            let configured = try await service.authorization.checkAccess(previous: nil)
            checks["configured-evidence"] = .bool(configured.observation?.evidence == .configured && configured.isSignedIn)
            let saved = service.authorization.credential!
            service.authorization.rejectCredential()
            try service.authorization.save(saved)
            let recovered = try await service.authorization.checkAccess(previous: nil)
            checks["saved-credential-recovers"] = .bool(recovered.isSignedIn)
            let runtime = VirtualMachine()
            let result = try await runtime.runAPI(source: "return { hasAgent: typeof ox !== 'undefined', data: await __apiRequest({path: 'items'}) };") { args in
                try await service.request(args, authenticated: true, allowsMutation: false)
            }
            checks["isolated-runtime"] = .bool(result.value?.objectValue?["hasAgent"]?.boolValue == false
                && result.value?.objectValue?["data"]?.objectValue?["items"]?.arrayValue?.count == 1)
            let action: JSONValue = .object([
                "id": .string("countItems"), "label": .string("Count items"),
                "requireAuth": .bool(false), "requireApproval": .bool(false),
                "inputSchema": .object(["type": .string("object"), "additionalProperties": .bool(false)]),
                "outputSchema": .object(["type": .string("integer")]),
            ])
            var manifest = try definition(fixtureID + "-invoke", auth: .object(["type": .string("none")])).manifest.objectValue!
            manifest["actions"] = .array([action])
            let source = #"""
            window.ox.install(1, ({action, request}) => {
              action('countItems', {invoke: async () => (await request({path: 'items'})).items.length});
            });
            """#
            let attached = Service(definition: try ServiceDefinition(manifest: .object(manifest)), actions: source, skills: [:], manager: manager)
            let invoked = await attached.apiService!.invoke(service: attached, actionID: "countItems", args: .object([:])) { _, _ in false }
            checks["attached-invocation"] = .bool((try? invoked.get())?.intValue == 1)
            let invalidInput = await attached.apiService!.invoke(service: attached, actionID: "countItems", args: .string("invalid")) { _, _ in false }
            checks["input-validation"] = .bool((try? invalidInput.get()) == nil)
            attached.apiService!.source = Service.Resolved(actions: source.replacingOccurrences(of: ".items.length", with: ".items"), skills: [:])
            let invalidOutput = await attached.apiService!.invoke(service: attached, actionID: "countItems", args: .object([:])) { _, _ in false }
            checks["output-validation"] = .bool((try? invalidOutput.get()) == nil)
            attached.apiService!.source = Service.Resolved(actions: source.replacingOccurrences(of: "countItems", with: "undeclared"), skills: [:])
            let invalidInstaller = await attached.apiService!.invoke(service: attached, actionID: "countItems", args: .object([:])) { _, _ in false }
            checks["registration-validation"] = .bool((try? invalidInstaller.get()) == nil)
            var writeAction = action.objectValue!
            writeAction["requireApproval"] = .bool(true)
            manifest["actions"] = .array([.object(writeAction)])
            let write = Service(definition: try ServiceDefinition(manifest: .object(manifest)), actions: source, skills: [:], manager: manager)
            let before = APIServiceFixtureProtocol.requests.withLock { $0.count }
            let denied = await write.apiService!.invoke(service: write, actionID: "countItems", args: .object([:])) { _, _ in false }
            checks["approval-before-network"] = .bool((try? denied.get()) == nil && APIServiceFixtureProtocol.requests.withLock { $0.count } == before)
            service.authorization.clear()
            do {
                _ = try await service.request(request, authenticated: true, allowsMutation: false)
                checks["clear-credentials"] = .bool(false)
            } catch { checks["clear-credentials"] = .bool(true) }
        } catch {
            checks["unexpected-error"] = .string(error.localizedDescription)
        }
        let access = await ServiceAccessChecks.run(manager: manager)
        for (name, result) in access.objectValue?["checks"]?.objectValue ?? [:] {
            checks["access-" + name] = result
        }
        let passed = checks.values.allSatisfy { $0.boolValue == true }
        return .object(["ok": .bool(passed), "checks": .object(checks)])
    }

    private static func definition(_ domain: String, auth: JSONValue) throws -> ServiceDefinition {
        try ServiceDefinition(manifest: .object([
            "kind": .string("api"), "domain": .string(domain), "name": .string("API fixture"),
            "baseUrl": .string("https://api-fixture.invalid/v1/"), "auth": auth, "actions": .array([]),
        ]))
    }
}
@MainActor
enum ServiceAccessChecks {
    static func run(manager: ServiceManager) async -> JSONValue {
        var checks: [String: JSONValue] = [:]
        do {
            let definition = try ServiceDefinition(manifest: .object([
                "domain": .string("access-fixture.invalid"), "name": .string("Access fixture"),
                "baseUrl": .string("https://access-fixture.invalid/"), "actions": .array([]),
            ]))
            let service = Service(definition: definition, manager: manager)
            var probes = 0
            let read: @MainActor () async throws -> Service.Auth = {
                probes += 1
                return observed(.signedIn)
            }
            service.setAuth(observed(.signedIn))
            await service.access.check(service, policy: .cached, reason: .serviceDetail, read: read)
            checks["detail-cache"] = .bool(probes == 0 && service.auth.isSignedIn && !service.auth.isChecking)
            service.setAuth(observed(.signedOut))
            await service.access.check(service, policy: .cached, reason: .requireAuth, read: read)
            checks["signed-out-cache"] = .bool(probes == 0 && service.auth.isSignedOut)
            await service.access.check(service, policy: .current, reason: .modelSignIn, read: read)
            checks["explicit-refresh"] = .bool(probes == 1 && service.auth.isSignedIn)
            let preflight = service.access.signInPreflight
            await service.access.check(service, policy: .current, reason: .pendingSignIn, preflight: preflight, read: read)
            checks["control-shares-preflight"] = .bool(probes == 1)
            await service.access.check(service, policy: .current, reason: .pendingSignIn, preflight: preflight, read: read)
            checks["reopened-control-refreshes"] = .bool(probes == 2)
            service.setAuth(.observed(Service.AuthObservation(value: .signedIn, observedAt: .distantPast)))
            await service.access.check(service, policy: .cached, reason: .serviceDetail, read: read)
            checks["expired-cache"] = .bool(probes == 3)
            service.setAuth(.unavailable(previous: service.auth.observation, error: "fixture"))
            await service.access.check(service, policy: .cached, reason: .serviceDetail, read: read)
            checks["unavailable-refreshes"] = .bool(probes == 4)

            var continuation: CheckedContinuation<Service.Auth, Never>?
            let blocked: @MainActor () async throws -> Service.Auth = {
                probes += 1
                return await withCheckedContinuation { continuation = $0 }
            }
            let first = Task { @MainActor in
                await service.access.check(service, policy: .current, reason: .modelSignIn, read: blocked)
            }
            while continuation == nil { await Task.yield() }
            var secondStarted = false
            let second = Task { @MainActor in
                secondStarted = true
                return await service.access.check(service, policy: .current, reason: .pendingSignIn, read: blocked)
            }
            while !secondStarted { await Task.yield() }
            continuation?.resume(returning: observed(.signedIn))
            _ = await (first.value, second.value)
            checks["concurrent-checks-join"] = .bool(probes == 5)

            continuation = nil
            let stale = Task { @MainActor in
                await service.access.check(service, policy: .current, reason: .debug, read: blocked)
            }
            while continuation == nil { await Task.yield() }
            service.setAuth(observed(.signedOut))
            continuation?.resume(returning: observed(.signedIn))
            await stale.value
            checks["newer-state-wins"] = .bool(service.auth.isSignedOut)

            service.setAuth(.signingIn(previous: service.auth.observation))
            let beforeSignIn = probes
            let waiting = Task { @MainActor in
                await service.access.check(service, policy: .cached, reason: .serviceDetail, read: read)
            }
            while service.authenticationWaiters.isEmpty { await Task.yield() }
            service.setAuth(observed(.signedIn))
            await waiting.value
            checks["completed-sign-in-reuses-cache"] = .bool(probes == beforeSignIn && service.auth.isSignedIn)
        } catch {
            checks["unexpected-error"] = .string(error.localizedDescription)
        }
        return .object(["ok": .bool(checks.values.allSatisfy { $0.boolValue == true }), "checks": .object(checks)])
    }

    private static func observed(_ value: Service.AuthObservation.Value) -> Service.Auth {
        .observed(Service.AuthObservation(value: value, observedAt: Date()))
    }
}
#endif
