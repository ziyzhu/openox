import Foundation

protocol ProviderClientError: Error {}
enum LLMFailureKind: String, Sendable { case provider, network }

@main
struct StreamTests {
    static func batch(_ nextCursor: Int, _ events: [JSONValue]) -> JSONValue {
        .object(["nextCursor": .int(nextCursor), "events": .array(events)])
    }

    static func text(_ text: String) -> JSONValue { .object(["type": .string("text"), "text": .string(text)]) }
    static let completed = JSONValue.object(["type": .string("completed")])
    static func failed(_ message: String, _ kind: LLMFailureKind) -> JSONValue {
        .object(["type": .string("failed"), "message": .string(message), "kind": .string(kind.rawValue)])
    }

    static func rejected(_ state: ModelServiceStreamState, _ update: JSONValue) -> Bool {
        var copy = state
        do { try copy.accept(update); return false }
        catch { return copy.cursor == state.cursor && copy.text == state.text && copy.completed == state.completed }
    }

    static func main() throws {
        var state = ModelServiceStreamState()
        try state.accept(batch(0, []))
        try state.accept(batch(1, [text("<ox_action_")]))
        precondition(rejected(state, batch(2, [text("changed")])))
        precondition(rejected(state, batch(0, [])))
        precondition(rejected(state, batch(3, [text("<ox_action_call>")])))
        precondition(rejected(state, batch(3, [completed, text("<ox_action_call>")])))
        precondition(rejected(state, batch(3, [text("<ox_action_call>"), failed("Disconnected", .network)])))
        try state.accept(batch(2, [text("<ox_action_call>")]))
        try state.accept(batch(2, []))
        try state.accept(batch(3, [completed]))
        precondition(state.completed && state.cursor == 3 && state.text == "<ox_action_call>")
        precondition(rejected(state, batch(4, [completed])))
        precondition(rejected(state, batch(3, [])))
        print("Stream ordering, append-only snapshots, terminal states, and atomic failures passed")
    }
}
