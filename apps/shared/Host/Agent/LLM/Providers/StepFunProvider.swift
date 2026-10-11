import Foundation

nonisolated enum StepFunProvider {
    static let profile = OpenAICompatibleProvider(
        id: "stepfun",
        displayName: RegionalValue("StepFun API"),
        regions: [.china],
        endpoint: regionalURL("https://api.stepfun.com/v1"),
        reasoningReplayModelIDs: ["step-3.7-flash"],
        iconURL: regionalURL("https://openox.ai/assets/services/model-providers/stepfun/favicon.png"),
        website: regionalURL("https://platform.stepfun.com/interface-key")
    )
}
