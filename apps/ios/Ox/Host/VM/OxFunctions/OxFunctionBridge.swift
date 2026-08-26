import Foundation

@MainActor
public protocol OxFunctionBridge: AnyObject {
    func readJavaScriptOutput(id: String, purpose: String) async throws -> JSONValue?
    func inspectApp(purpose: String) async throws -> JSONValue?
    func renameChat(title: String, purpose: String) async throws -> JSONValue?
    func invokeAction(name: String, args: JSONValue?, purpose: String) async throws -> JSONValue?
    func searchWeb(query: String, purpose: String) async throws -> JSONValue?
    func fetchWeb(url: String, options: JSONValue?, purpose: String) async throws -> JSONValue?
    func attachArtifact(filename: String, purpose: String) async throws -> JSONValue?
    func listFileSystem(path: String, options: JSONValue?, purpose: String) async throws -> JSONValue?
    func readFileSystem(path: String, options: JSONValue?, purpose: String) async throws -> JSONValue?
    func writeFileSystem(path: String, content: String, purpose: String) async throws -> JSONValue?
    func editFileSystem(path: String, edits: JSONValue?, purpose: String) async throws -> JSONValue?
    func deleteFileSystem(path: String, purpose: String) async throws -> JSONValue?
    func globFileSystem(pattern: String, path: String, options: JSONValue?, purpose: String) async throws -> JSONValue?
    func grepFileSystem(pattern: String, path: String, options: JSONValue?, purpose: String) async throws -> JSONValue?
    func findServices(query: String, purpose: String) async throws -> JSONValue?
    func listAttachedServices(kind: String?, purpose: String) async throws -> JSONValue?
    func inspectService(domain: String, actions: [String]?, purpose: String) async throws -> JSONValue?
    func createService(kind: String, domain: String, purpose: String) async throws -> JSONValue?
    func copyService(domain: String, purpose: String) async throws -> JSONValue?
    func deleteService(domain: String, purpose: String) async throws -> JSONValue?
    func serviceGitStatus(repository: String, purpose: String) async throws -> JSONValue?
    func serviceGitLog(repository: String, limit: Int, cursor: String?, purpose: String) async throws -> JSONValue?
    func serviceGitShow(repository: String, commitHash: String, path: String?, purpose: String) async throws -> JSONValue?
    func serviceGitDiff(repository: String, commitHash: String?, baseCommitHash: String?, path: String?, purpose: String) async throws -> JSONValue?
    func serviceGitCheckout(repository: String, commitHash: String, purpose: String) async throws -> JSONValue?
    func serviceGitCommit(message: String, purpose: String) async throws -> JSONValue?
    func serviceGitRevert(commitHash: String, message: String, purpose: String) async throws -> JSONValue?
    func serviceGitRestore(path: String?, purpose: String) async throws -> JSONValue?
    func attachService(domain: String, purpose: String) async throws -> JSONValue?
    func detachService(domain: String, purpose: String) async throws -> JSONValue?
    func signInService(domain: String, purpose: String) async throws -> JSONValue?
    func solveService(domain: String, args: JSONValue, purpose: String) async throws -> JSONValue?
    func payService(domain: String, args: JSONValue, purpose: String) async throws -> JSONValue?
    func createSkill(name: String, description: String, instructions: String, services: [String], purpose: String) async throws -> JSONValue?
    func copySkill(source: String, name: String, purpose: String) async throws -> JSONValue?
    func deleteSkill(name: String, purpose: String) async throws -> JSONValue?
    func reportProgress(message: String, purpose: String) async throws -> JSONValue?
    func chooseUser(body: String, options: [String], purpose: String) async throws -> JSONValue?
    func presentShoveler(value: JSONValue?, purpose: String) async throws -> JSONValue?
    func presentVideo(value: JSONValue?, purpose: String) async throws -> JSONValue?
    func importWebArtifact(url: String, filename: String?, purpose: String) async throws -> JSONValue?
    func renameArtifact(filename: String, newFilename: String, purpose: String) async throws -> JSONValue?
    func presentArtifact(filename: String, purpose: String) async throws -> JSONValue?
    func presentArtifacts(filenames: [String], purpose: String) async throws -> JSONValue?
}
