import Foundation

let input = try JSONDecoder().decode(JSONValue.self, from: FileHandle.standardInput.readDataToEndOfFile()).objectValue ?? [:]
let pages = input["pages"]?.arrayValue ?? []
let merged = OxSearch.mergeSearchResults(pages)
let contracts = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
let schema = contracts.objectValue?["ox.web.search"]?.objectValue?["outputSchema"] ?? .null
var response = input["response"]?.objectValue ?? ["query": .string("fixture"), "results": .array(pages), "errors": .array([])]
if input["legacy"] != .bool(true) { response["mergedResults"] = .array(merged) }
let issues = JSONSchemaValidator.validate(.object(response), against: schema, definitions: [:])
let output: JSONValue = .object([
    "merged": .array(merged), "response": .object(response),
    "issues": .array(issues.map { .string(String(describing: $0)) }),
    "nativeMergedSchema": OxSearch.mergedResultSchema, "nativePageSchema": OxSearch.resultSchema,
])
FileHandle.standardOutput.write(try JSONEncoder().encode(output))
