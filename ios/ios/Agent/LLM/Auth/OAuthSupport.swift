import CryptoKit
import Foundation
import Security

nonisolated struct OAuthPKCE: Sendable {
    let verifier: String
    let challenge: String
}

nonisolated enum OAuthSupport {
    static func makePKCE() -> OAuthPKCE {
        var bytes = [UInt8](repeating: 0, count: 64)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            bytes = Array(UUID().uuidString.utf8)
        }
        let verifier = Data(bytes).map { String(format: "%02x", $0) }.joined()
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncodedString()
        return OAuthPKCE(verifier: verifier, challenge: challenge)
    }

    static func formEncoded(_ form: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let pairs = form.sorted { $0.key < $1.key }.map { key, value in
            let encodedKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let encodedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(encodedKey)=\(encodedValue)"
        }
        return Data(pairs.joined(separator: "&").utf8)
    }

    static func queryValue(_ name: String, in url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first { $0.name == name }?
            .value
    }

    static func jwtClaims(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count == 3, let data = Data(base64URLEncoded: String(parts[1])) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}

nonisolated private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URLEncoded string: String) {
        var value = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        value += String(repeating: "=", count: (4 - value.count % 4) % 4)
        self.init(base64Encoded: value)
    }
}
