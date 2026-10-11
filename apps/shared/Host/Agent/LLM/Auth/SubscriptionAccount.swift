import Foundation

public typealias OAuthAuthorizationPresenter = @MainActor (URL, String) async -> URL?
public typealias DeviceAuthorizationPoll = @Sendable () async throws -> Bool
public typealias DeviceAuthorizationPresenter = @MainActor (URL, String, @escaping DeviceAuthorizationPoll) async -> Bool

nonisolated public struct SubscriptionAuthorizationPresenter {
    public let oauth: OAuthAuthorizationPresenter
    public let device: DeviceAuthorizationPresenter

    public init(oauth: @escaping OAuthAuthorizationPresenter, device: @escaping DeviceAuthorizationPresenter) {
        self.oauth = oauth
        self.device = device
    }
}

// A provider-neutral seam for clients authenticated by an existing consumer
// subscription (OAuth) rather than a pasted API key. The generic LLM layer
// stays ignorant of any specific provider; concrete accounts encapsulate the
// flow and token lifecycle.
nonisolated public protocol SubscriptionAccount: Sendable {
    var providerName: String { get }
    var isSignedIn: Bool { get }
    var planLabel: String? { get }
    var accountLabel: String? { get }
    var policyNotice: String? { get }
    @MainActor func signIn(using presenter: SubscriptionAuthorizationPresenter) async throws -> Bool
    @MainActor func signOut()
}

nonisolated extension SubscriptionAccount {
    public var accountLabel: String? { nil }
    public var policyNotice: String? { nil }
}

nonisolated extension ProviderClient {
    public var subscriptionAccount: (any SubscriptionAccount)? { nil }
}
