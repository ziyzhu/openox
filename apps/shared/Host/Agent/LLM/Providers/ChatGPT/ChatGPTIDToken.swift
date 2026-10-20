import Foundation
import Security

nonisolated enum ChatGPTIDToken {
    static func configuration() async throws -> [String: Any] {
        try await json(URL(string: "https://auth.openai.com/.well-known/openid-configuration")!)
    }

    static func validate(_ token: String, clientID: String, nonce: String?) async throws -> (subject: String, email: String?) {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3,
              let headerData = decode(parts[0]), let payload = decode(parts[1]), let signature = decode(parts[2]),
              let header = try JSONSerialization.jsonObject(with: headerData) as? [String: Any],
              header["alg"] as? String == "RS256", let keyID = header["kid"] as? String,
              let claims = try JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            throw ChatGPTAuthError(message: "ChatGPT returned an invalid ID token")
        }
        let metadata = try await configuration()
        guard metadata["issuer"] as? String == "https://auth.openai.com",
              let address = metadata["jwks_uri"] as? String, let url = URL(string: address),
              url.scheme == "https", url.host == "auth.openai.com" else {
            throw ChatGPTAuthError(message: "ChatGPT identity configuration is invalid")
        }
        let keys = try await json(url)["keys"] as? [[String: Any]] ?? []
        guard let jwk = keys.first(where: { $0["kid"] as? String == keyID && $0["kty"] as? String == "RSA" }),
              (jwk["use"] as? String).map({ $0 == "sig" }) ?? true,
              (jwk["alg"] as? String).map({ $0 == "RS256" }) ?? true,
              let modulus = (jwk["n"] as? String).flatMap(decode),
              let exponent = (jwk["e"] as? String).flatMap(decode) else {
            throw ChatGPTAuthError(message: "ChatGPT ID-token signing key is unavailable")
        }
        let keyData = der(0x30, derInteger(modulus) + derInteger(exponent))
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic]
        guard let key = SecKeyCreateWithData(keyData as CFData, attributes as CFDictionary, nil),
              SecKeyVerifySignature(key, .rsaSignatureMessagePKCS1v15SHA256, Data("\(parts[0]).\(parts[1])".utf8) as CFData, signature as CFData, nil) else {
            throw ChatGPTAuthError(message: "ChatGPT ID-token signature could not be verified")
        }
        let audiences = (claims["aud"] as? [String]) ?? (claims["aud"] as? String).map { [$0] } ?? []
        guard claims["iss"] as? String == metadata["issuer"] as? String,
              audiences.contains(clientID),
              audiences.count == 1 || claims["azp"] as? String == clientID,
              let expiry = claims["exp"] as? Double, expiry > Date().timeIntervalSince1970,
              let subject = claims["sub"] as? String, !subject.isEmpty,
              nonce == nil || claims["nonce"] as? String == nonce else {
            throw ChatGPTAuthError(message: "ChatGPT ID-token identity, expiry, or nonce is invalid")
        }
        return (subject, claims["email"] as? String)
    }

    private static func json(_ url: URL) async throws -> [String: Any] {
        let (data, response) = try await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 30))
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ChatGPTAuthError(message: "ChatGPT identity metadata is unavailable")
        }
        return json
    }

    private static func decode(_ string: String) -> Data? {
        let base = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        return Data(base64Encoded: base + String(repeating: "=", count: (4 - base.count % 4) % 4))
    }

    private static func derInteger(_ data: Data) -> Data {
        der(0x02, data.first.map { $0 & 0x80 != 0 } == true ? Data([0]) + data : data)
    }

    private static func der(_ tag: UInt8, _ value: Data) -> Data {
        var length = value.count
        var bytes: [UInt8] = []
        repeat {
            bytes.insert(UInt8(length & 0xff), at: 0)
            length >>= 8
        } while length > 0
        let prefix = value.count < 128 ? Data([UInt8(value.count)]) : Data([0x80 | UInt8(bytes.count)] + bytes)
        return Data([tag]) + prefix + value
    }
}
