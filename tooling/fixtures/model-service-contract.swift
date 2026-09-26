import Foundation

enum ServiceDefinition {
    enum ValidationError: Error {
        case invalid(String)
    }
}

enum Manifest {
    struct Action: Decodable {
        let id: String
        let inputSchema: JSONValue?
        let outputSchema: JSONValue?
        let blocking: Bool
        let raw: [String: JSONValue]

        init(from decoder: Decoder) throws {
            raw = try decoder.singleValueContainer().decode([String: JSONValue].self)
            id = raw["id"]?.stringValue ?? ""
            inputSchema = raw["inputSchema"]
            outputSchema = raw["outputSchema"]
            blocking = raw["blocking"]?.boolValue == true
        }
    }
}

@main
struct ContractTests {
    struct Sample: Decodable {
        let actions: [Manifest.Action]
        let definitions: [String: JSONValue]
        let isWeb: Bool
    }

    static func main() throws {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        let samples = try JSONDecoder().decode([Sample].self, from: data)
        let results = samples.map { sample in
            do {
                try ModelServiceContract.validate(sample.actions, definitions: sample.definitions, isWeb: sample.isWeb)
                return true
            } catch { return false }
        }
        FileHandle.standardOutput.write(try JSONEncoder().encode(results))
    }
}
