import Foundation

nonisolated enum StepFunProvider {
    static let profile = OpenAICompatibleProvider(
        id: "stepfun",
        displayName: RegionalValue("StepFun"),
        regions: [.china],
        endpoint: regionalURL("https://api.stepfun.com/v1"),
        reasoningReplayModelIDs: ["step-3.7-flash"],
        website: regionalURL("https://platform.stepfun.com/interface-key")
    )
}
