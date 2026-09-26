import Foundation

protocol ProviderClientError: Error {}
enum LLMFailureKind: String, Sendable { case provider, network }

@main
struct StreamTests {
    static func rejected(_ state: ModelServiceStreamState, _ update: WebsiteGenerationUpdate) -> Bool {
        var copy = state
        do { try copy.accept(update); return false }
        catch { return copy.cursor == state.cursor && copy.text == state.text && copy.completed == state.completed }
    }

    static func main() throws {
        var state = ModelServiceStreamState()
        try state.accept(.init(nextCursor: 0, events: []))
        try state.accept(.init(nextCursor: 1, events: [.textSnapshot("<ox_action_")]))
        precondition(rejected(state, .init(nextCursor: 2, events: [.textSnapshot("changed")])))
        precondition(rejected(state, .init(nextCursor: 0, events: [])))
        precondition(rejected(state, .init(nextCursor: 3, events: [.textSnapshot("<ox_action_call>")])))
        precondition(rejected(state, .init(nextCursor: 3, events: [.completed, .textSnapshot("<ox_action_call>")])))
        precondition(rejected(state, .init(nextCursor: 3, events: [.textSnapshot("<ox_action_call>"), .failed("Disconnected", .network)])))
        try state.accept(.init(nextCursor: 2, events: [.textSnapshot("<ox_action_call>")]))
        try state.accept(.init(nextCursor: 2, events: []))
        try state.accept(.init(nextCursor: 3, events: [.completed]))
        precondition(state.completed && state.cursor == 3 && state.text == "<ox_action_call>")
        precondition(rejected(state, .init(nextCursor: 4, events: [.completed])))
        precondition(rejected(state, .init(nextCursor: 3, events: [])))
        print("Stream ordering, append-only snapshots, terminal states, and atomic failures passed")
    }
}
