import Foundation

@main
struct HistoryTests {
    static func turn(_ role: String, _ text: String) -> JSONValue {
        .object(["role": .string(role), "text": .string(text)])
    }

    static func attachmentTurn(_ role: String, name: String) -> JSONValue {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        func encode(_ value: JSONValue) -> String {
            String(decoding: try! encoder.encode(value), as: UTF8.self)
        }
        let content = encode(.object(["uploaded_file": .string(name)]))
        if role == "tool" {
            let payload = encode(.object(["name": .string("run"), "call_id": .string("call"), "is_error": .bool(false), "content": .string(content)]))
            return turn(role, "<ox_action_result>\n\(payload)\n</ox_action_result>")
        }
        return turn(role, content)
    }

    static func main() {
        let system = turn("system", "Instructions")
        let user = turn("user", "Hello")
        let reply = ModelConversationHistory.assistantTurn("<ox_action_call>{\"arguments\":{},\"name\":\"run\"}</ox_action_call>")
        let result = turn("tool", "<ox_action_result>{}</ox_action_result>")
        let history = [system, user, reply]
        precondition(ModelConversationHistory.newTurns(after: history, in: history + [result]) == [result])
        precondition(ModelConversationHistory.newTurns(after: history, in: history + [result, turn("user", "Also")])?.count == 2)
        precondition(ModelConversationHistory.newTurns(after: [], in: history + [result]) == nil)
        precondition(ModelConversationHistory.newTurns(after: history, in: history) == nil)
        precondition(ModelConversationHistory.newTurns(after: history, in: [turn("system", "Changed"), user, reply, result]) == nil)
        precondition(ModelConversationHistory.newTurns(after: history, in: [system, user, turn("assistant", "Other reply"), result]) == nil)
        precondition(ModelConversationHistory.newTurns(after: history, in: [system, turn("user", "Summary"), result]) == nil)
        precondition(ModelConversationHistory.newTurns(after: history, in: history + [turn("assistant", "Extra"), result]) == nil)
        let file = turn("user", "{\"filename\":\"a.png\",\"mime_type\":\"image/png\",\"uploaded_file\":\"ox-2-a.png\"}")
        let earlier = turn("user", "{\"filename\":\"b.png\",\"mime_type\":\"image/png\",\"uploaded_file\":\"ox-1-b.png\"}")
        precondition(ModelConversationHistory.referencedFileNames(["ox-1-b.png", "ox-2-a.png"], in: [file], excluding: [earlier]) == ["ox-2-a.png"])
        precondition(ModelConversationHistory.referencedFileNames(["ox-1-b.png"], in: [earlier], excluding: [earlier]).isEmpty)
        for name in ["ox-3-screenshot.png", "ox-4-quote\"back\\slash.png"] {
            let tool = attachmentTurn("tool", name: name)
            let user = attachmentTurn("user", name: name)
            precondition(ModelConversationHistory.referencedFileNames([name], in: [tool], excluding: history) == [name])
            precondition(ModelConversationHistory.referencedFileNames([name], in: [user], excluding: history) == [name])
            precondition(ModelConversationHistory.referencedFileNames([name], in: [tool], excluding: [tool]).isEmpty)
            precondition(ModelConversationHistory.referencedFileNames([name], in: [user], excluding: [tool]).isEmpty)
            precondition(ModelConversationHistory.referencedFileNames([name], in: [tool], excluding: [user]).isEmpty)
        }
        print("Continuation history matching passed")
    }
}
