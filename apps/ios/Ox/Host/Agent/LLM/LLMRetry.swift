import Foundation

nonisolated struct LLMRetryPolicy: Sendable {
    var maxRetries: Int
    var baseDelayMilliseconds: Int

    func delay(forRetry retry: Int) -> Duration {
        .milliseconds(baseDelayMilliseconds * (1 << max(0, retry - 1)))
    }

    static let compaction = LLMRetryPolicy(maxRetries: 2, baseDelayMilliseconds: 250)
}

nonisolated func isRetryableLLMFailure(_ message: AssistantMessage) -> Bool {
    guard message.stopReason == .error else { return false }
    return isRetryableLLMFailure(
        message: message.errorMessage ?? "",
        kind: message.failureKind
    )
}

nonisolated func isRetryableLLMFailure(_ error: Error) -> Bool {
    isRetryableLLMFailure(
        message: (error as? any LLMClientError)?.message ?? error.localizedDescription,
        kind: llmFailureKind(error: error)
    )
}

private nonisolated func isRetryableLLMFailure(message: String, kind: LLMFailureKind?) -> Bool {
    let value = message.lowercased()
    let permanentLimits = [
        "insufficient_quota",
        "out of budget",
        "quota exceeded",
        "quota is exhausted",
        "exceeded your current quota",
        "billing",
        "monthly usage limit",
        "available balance",
        "gousagelimiterror",
        "freeusagelimiterror",
    ]
    if permanentLimits.contains(where: value.contains) { return false }

    switch kind {
    case .network, .rateLimited:
        return true
    case .authentication, .unsupportedInput, .contextOverflow:
        return false
    case .provider, nil:
        let transientFailures = [
            "overloaded",
            "rate limit",
            "rate-limit",
            "rate_limit",
            "too many requests",
            "429",
            "500",
            "502",
            "503",
            "504",
            "524",
            "service unavailable",
            "server error",
            "internal error",
            "provider returned error",
            "network error",
            "connection error",
            "connection refused",
            "connection lost",
            "other side closed",
            "fetch failed",
            "getaddrinfo",
            "enotfound",
            "eai_again",
            "upstream connect",
            "reset before headers",
            "socket hang up",
            "socket connection was closed",
            "timed out",
            "timeout",
            "terminated",
            "websocket closed",
            "websocket error",
            "ended without",
            "http2 request did not get a response",
            "retry delay",
            "you can retry your request",
            "try your request again",
            "please retry your request",
            "resourceexhausted",
        ]
        return transientFailures.contains(where: value.contains)
    }
}
