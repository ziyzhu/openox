import Foundation

extension MockLLMClient {
    public static var isEnabled: Bool {
        #if targetEnvironment(simulator)
        !SimEnv.mockLLMDisabled
        #else
        false
        #endif
    }
}
