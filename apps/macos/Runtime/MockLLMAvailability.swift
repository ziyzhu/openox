import Foundation

extension MockLLMClient {
    public static var isEnabled: Bool {
        #if DEBUG
        !ProcessInfo.processInfo.arguments.contains("--disable-mock-llm")
        #else
        false
        #endif
    }
}
