import Foundation

@MainActor
public protocol OxFunctionBridge: AnyObject {
    func startConversation(prompt: String, title: String, purpose: String) async throws -> JSONValue?
    func deleteConversation(id: String, purpose: String) async throws -> JSONValue?
    func providerOperation(name: String, arguments: JSONValue, purpose: String) async throws -> JSONValue?
    func secretOperation(name: String, arguments: JSONValue, purpose: String) async throws -> JSONValue?
    func appModel(purpose: String) async throws -> JSONValue?
    func setAppModel(options: JSONValue, purpose: String) async throws -> JSONValue?
    func renameConversation(title: String, purpose: String) async throws -> JSONValue?
    func invokeAction(name: String, args: JSONValue?, session: JSONValue?, pageURL: String?, purpose: String) async throws -> JSONValue?
    func searchWeb(arguments: JSONValue, purpose: String) async throws -> JSONValue?
    func fetchWeb(url: String, options: JSONValue?, purpose: String) async throws -> JSONValue?
    func browserOperation(action: String, arguments: JSONValue, purpose: String) async throws -> JSONValue?
    func analyzeVision(filename: String, purpose: String) async throws -> JSONValue?
    func fileSystemOperation(name: String, arguments: JSONValue) async throws -> JSONValue?
    func findServices(query: String, purpose: String) async throws -> JSONValue?
    func listServices(kind: String?, purpose: String) async throws -> JSONValue?
    func listAttachedServices(kind: String?, purpose: String) async throws -> JSONValue?
    func inspectService(domain: String, cursor: String?, purpose: String) async throws -> JSONValue?
    func validateService(domain: String, purpose: String) async throws -> JSONValue?
    func createService(kind: String, domain: String, endpoint: String?, transport: String?, faviconURL: JSONValue?, purpose: String) async throws -> JSONValue?
    func updateService(domain: String, fields: [String: JSONValue], purpose: String) async throws -> JSONValue?
    func deleteService(domain: String, purpose: String) async throws -> JSONValue?
    func appRepositories(purpose: String) async throws -> JSONValue?
    func connectRepository(origin: String, purpose: String) async throws -> JSONValue?
    func repositoryConflicts(service: String?, compare: Bool, purpose: String) async throws -> JSONValue?
    func resolveRepositoryConflict(service: String, repository: String, purpose: String) async throws -> JSONValue?
    func syncRepository(repository: String, purpose: String) async throws -> JSONValue?
    func enableRepository(repository: String, enabled: Bool, purpose: String) async throws -> JSONValue?
    func disconnectRepository(repository: String, purpose: String) async throws -> JSONValue?
    func attachService(domain: String, purpose: String) async throws -> JSONValue?
    func detachService(domain: String, purpose: String) async throws -> JSONValue?
    func showServicePage(name: String, args: JSONValue?, session: JSONValue?, pageURL: String?, waitForUserInteraction: Bool, purpose: String) async throws -> JSONValue?
    func loginService(domain: String, purpose: String) async throws -> JSONValue?
    func createSkill(name: String, description: String, instructions: String, services: [String], purpose: String) async throws -> JSONValue?
    func copySkill(source: String, name: String, purpose: String) async throws -> JSONValue?
    func shareSkill(name: String, purpose: String) async throws -> JSONValue?
    func deleteSkill(name: String, purpose: String) async throws -> JSONValue?
    func createSchedule(options: JSONValue, purpose: String) async throws -> JSONValue?
    func completeSchedule(purpose: String) async throws -> JSONValue?
    func listSchedules(purpose: String) async throws -> JSONValue?
    func deleteSchedule(id: String, purpose: String) async throws -> JSONValue?
    func enableSchedule(id: String, enabled: Bool, purpose: String) async throws -> JSONValue?
    func runSchedule(id: String, purpose: String) async throws -> JSONValue?
    func reportProgress(message: String, purpose: String) async throws -> JSONValue?
    func followUser(intents: JSONValue, purpose: String) async throws -> JSONValue?
    func chooseUser(body: String, options: [String], purpose: String) async throws -> JSONValue?
}

extension OxFunctionBridge {
    public func providerOperation(name: String, arguments: JSONValue, purpose: String) async throws -> JSONValue? {
        throw RuntimeError.bridge("Provider management is unavailable in this context")
    }

    public func secretOperation(name: String, arguments: JSONValue, purpose: String) async throws -> JSONValue? {
        throw RuntimeError.bridge("Secret is unavailable in this context")
    }
}
