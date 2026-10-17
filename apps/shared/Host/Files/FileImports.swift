import Foundation

extension Conversation {
    func importRemoteMCPFiles(_ values: [RemoteMCPFile]) async throws {
        guard !values.isEmpty else { return }
        try requireProfileMutation(Actions.fsWrite)
        var files: [FileItem] = []
        for value in values {
            files.append(try await FileImporter.importDataAsync(
                value.data,
                suggestedName: value.suggestedFilename,
                in: scope,
                conversation: durableRoute?.reference
            ))
        }
        for file in files { embedFile(file) }
        Log.session.info("Conversation.importRemoteMCPFiles count=\(files.count) bytes=\(values.reduce(0) { $0 + $1.data.count })")
    }
}
