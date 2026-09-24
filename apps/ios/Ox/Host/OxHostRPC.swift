#if targetEnvironment(simulator)
import Foundation

@MainActor
enum OxHostRPC {
    static var description: JSONValue {
        .object([
            "implementation": .object([
                "name": .string("Ox"),
                "version": .string(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"),
                "build": .string(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"),
            ]),
            "protocols": .object([
                "repository": versions(HostProtocols.repository),
                "service": versions(HostProtocols.service),
            ]),
            "methods": .array(OxHostProtocol.Method.allCases.map { .string($0.rawValue) }),
        ])
    }

    private static func versions(_ values: [Int]) -> JSONValue { .array(values.map { .int($0) }) }

    static func handle(_ data: Data, host: any OxHost) async -> JSONValue? {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            return failure(id: .null, code: -32700, message: "Parse error")
        }
        if case .array(let requests) = value {
            guard !requests.isEmpty else { return failure(id: .null, code: -32600, message: "Invalid Request") }
            var responses: [JSONValue] = []
            for value in requests {
                if let response = await request(value, host: host) { responses.append(response) }
            }
            return responses.isEmpty ? nil : .array(responses)
        }
        return await request(value, host: host)
    }

    private static func request(_ value: JSONValue, host: any OxHost) async -> JSONValue? {
        guard let fields = value.objectValue,
              fields["jsonrpc"] == .string("2.0"),
              let name = fields["method"]?.stringValue,
              validID(fields["id"]) else {
            return failure(id: .null, code: -32600, message: "Invalid Request")
        }
        let response: JSONValue = await withCheckedContinuation { continuation in
            let reply = Reply(requestID: fields["id"] ?? .null, method: name) { continuation.resume(returning: $0) }
            guard let method = OxHostProtocol.Method(rawValue: name) else {
                reply.failure("Method not found", code: -32601)
                return
            }
            let params = fields["params"] == .array([]) ? JSONValue.object([:]) : fields["params"] ?? .object([:])
            guard params.objectValue != nil else {
                reply.failure("Parameters must be an object", code: -32602)
                return
            }
            do { try OxHostProtocol.invoke(method, params: params, host: host, reply: reply) }
            catch { reply.failure("Invalid params", code: -32602) }
        }
        return fields["id"] == nil ? nil : response
    }

    private static func validID(_ id: JSONValue?) -> Bool {
        switch id {
        case nil, .null, .string, .int, .double: true
        default: false
        }
    }

    private static func failure(id: JSONValue, code: Int, message: String, data: JSONValue? = nil) -> JSONValue {
        var error: [String: JSONValue] = ["code": .int(code), "message": .string(message)]
        if let data { error["data"] = data }
        return .object(["jsonrpc": .string("2.0"), "id": id, "error": .object(error)])
    }

    final class Reply {
        private let requestID: JSONValue
        private let method: String
        private var completion: ((JSONValue) -> Void)?
        var id: String { requestID.jsonString() }

        init(requestID: JSONValue, method: String, completion: @escaping (JSONValue) -> Void) {
            self.requestID = requestID
            self.method = method
            self.completion = completion
        }

        func success() { success(JSONValue.object([:])) }

        func success<T: Encodable>(_ value: T) {
            do {
                send(.object(["jsonrpc": .string("2.0"), "id": requestID, "result": try json(value)]))
            } catch {
                failure("Internal error", code: -32603)
            }
        }

        func failure(_ message: String, code: Int = -32000) {
            send(OxHostRPC.failure(id: requestID, code: code, message: message))
        }

        func failure<T: Encodable>(_ message: String, data: T) {
            do { send(OxHostRPC.failure(id: requestID, code: -32000, message: message, data: try json(data))) }
            catch { failure("Internal error", code: -32603) }
        }

        func complete<T: Encodable>(_ value: T, error: String?) {
            if let error { failure(error, data: value) }
            else { success(value) }
        }

        func complete(_ result: Result<JSONValue, Error>) {
            switch result {
            case .success(let value): success(JSONValue.object(["value": value]))
            case .failure(let error): failure(error.localizedDescription)
            }
        }

        private func json<T: Encodable>(_ value: T) throws -> JSONValue {
            try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
        }

        private func send(_ value: JSONValue) {
            guard let completion else {
                Log.app.error("OxHostRPC duplicate response method=\(method)")
                return
            }
            self.completion = nil
            let code = value.objectValue?["error"]?.objectValue?["code"]?.intValue ?? 0
            Log.app.debug("OxHostRPC completed method=\(method) code=\(code)")
            completion(value)
        }
    }
}
#endif
