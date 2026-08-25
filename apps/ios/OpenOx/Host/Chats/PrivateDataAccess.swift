import Foundation

struct PrivateDataRequest {
    let actionName: String
    let sourceName: String
    let storageName: String
    let dataName: String
    let range: String?
    let purpose: String?
}

struct PrivateDataAccessContext {
    struct Provider: Equatable {
        let id: String
        let name: String
        let location: LLMInferenceLocation
    }

    let chatRetention: ChatRetention
    let provider: Provider
}

@MainActor
protocol PrivateDataHost: AnyObject {
    var privateDataContext: PrivateDataAccessContext { get }
    func privateDataContinuation() -> ChatContinuation?
    func choosePrivateDataOption(prompt: String, options: [String]) async -> String
    func continuePrivateDataTemporarily(_ continuation: ChatContinuation)
}

@MainActor
struct PrivateDataAccess {
    unowned let host: any PrivateDataHost

    func authorize(_ request: PrivateDataRequest) async throws {
        try await authorizeStorage(request)
        try await authorizeDisclosure(request)
    }

    private func authorizeStorage(_ request: PrivateDataRequest) async throws {
        let current = host.privateDataContext
        guard current.chatRetention == .persisted else { return }
        guard let continuation = host.privateDataContinuation() else {
            throw RuntimeError.bridge("\(request.actionName): couldn't prepare a safe continuation for this request.")
        }
        let temporary = L10n.string("Start Temporary Chat")
        let notNow = L10n.string("Not Now")
        let prompt = """
        \(L10n.string("\(request.storageName) requires a temporary chat"))
        \(L10n.string("This request can't run in a saved chat. Start a temporary chat to continue."))
        """
        let choice = await host.choosePrivateDataOption(prompt: prompt, options: [temporary, notNow])
        guard choice == temporary else {
            Log.session.info("PrivateDataAccess.storage declined source=\(request.sourceName)")
            throw RuntimeError.bridge("\(request.actionName): the user chose not to continue.")
        }
        Log.session.info("PrivateDataAccess.storage selected source=\(request.sourceName) route=temporary")
        host.continuePrivateDataTemporarily(continuation)
        throw RuntimeError.bridge("\(request.actionName): continuing this request in a temporary chat.")
    }

    private func authorizeDisclosure(_ request: PrivateDataRequest) async throws {
        while true {
            let current = host.privateDataContext
            let provider = current.provider
            let notNow = L10n.string("Not Now")
            let approval: String
            let title: String
            let destination: String
            switch provider.location {
            case .remote, .userHosted:
                approval = L10n.string("Share Once")
                title = L10n.string("Share with \(provider.name)?")
                destination = L10n.string("and send it to \(provider.name) to answer this request.")
            case .onDevice:
                approval = L10n.string("Read Once")
                title = L10n.string("Read from \(request.sourceName)?")
                destination = L10n.string("to answer this request. The data won't be sent to a model provider.")
            }
            let range = request.range.map { L10n.string(" from \($0)") } ?? ""
            var lines = [
                title,
                L10n.string("Ox will read your \(request.dataName)\(range) \(destination)")
            ]
            lines.append(L10n.string("This temporary chat won't be saved by Ox or synced with iCloud."))
            if let purpose = boundedPurpose(request.purpose) {
                lines.append(L10n.string("Purpose: \(purpose)"))
            }
            let choice = await host.choosePrivateDataOption(prompt: lines.joined(separator: "\n"), options: [approval, notNow])
            guard choice == approval else {
                Log.session.info("PrivateDataAccess.disclosure declined source=\(request.sourceName) provider=\(provider.id)")
                throw RuntimeError.bridge("\(request.actionName): the user declined access.")
            }
            guard host.privateDataContext.provider == provider else {
                Log.session.info("PrivateDataAccess.disclosure providerChanged from=\(provider.id) to=\(host.privateDataContext.provider.id)")
                continue
            }
            Log.session.info("PrivateDataAccess.disclosure approved source=\(request.sourceName) provider=\(provider.id) location=\(String(describing: provider.location))")
            return
        }
    }

    private func boundedPurpose(_ purpose: String?) -> String? {
        let value = purpose?
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ") ?? ""
        guard !value.isEmpty else { return nil }
        return String(value.prefix(80))
    }
}
