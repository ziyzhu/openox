import Foundation

@MainActor
final class HostFileDownload {
    private struct Snapshot {
        let id = UUID()
        let data: Data
        let scope: ProfileScope
        let conversationID: UUID
        let grantID: String?
        var offset = 0
    }

    private enum State {
        case idle
        case preparing
        case sending(Snapshot)
    }

    private var state = State.idle

    func handle(_ request: OxHostProtocol.DownloadFileRequest, conversations: ConversationManager, reply: OxHostRPC.Reply) async {
        do {
            switch (request.path, request.attachmentId, request.transferId) {
            case (_?, nil, nil), (nil, _?, nil):
                guard case .idle = state else { throw RuntimeError.bridge("A file download is already in progress on this connection") }
                let session: Conversation
                switch OxHostProtocol.resolveSession(conversations, request.conversationId) {
                case .found(let found?): session = found
                case .found(nil): throw RuntimeError.bridge("No active conversation")
                case .error(let message): throw RuntimeError.bridge(message)
                }
                state = .preparing
                defer { if case .preparing = state { state = .idle } }
                let source: String
                if let path = request.path, !path.isEmpty, path.utf8.count <= 16_384 {
                    source = try await session.downloadFilePath(path)
                } else if let id = request.attachmentId, !id.isEmpty, id.utf8.count <= 960 {
                    source = try await session.downloadAttachmentPath(id)
                } else {
                    throw RuntimeError.bridge("Invalid download path or attachment ID")
                }
                let parts = source.split(separator: "/")
                let grantID = parts.first == "mounts" && parts.count > 2 ? String(parts[1]) : nil
                let data = try await session.downloadFileData(path: source)
                let snapshot = Snapshot(data: data, scope: session.scope, conversationID: session.id, grantID: grantID)
                Log.session.info("HostFileDownload.start conversation=\(session.id) bytes=\(data.count)")
                try send(snapshot, conversations: conversations, reply: reply)
            case (nil, nil, let id?) where request.conversationId == nil:
                guard case .sending(let snapshot) = state, UUID(uuidString: id) == snapshot.id else {
                    throw RuntimeError.bridge("File download is unavailable; start a new download")
                }
                state = .idle
                try send(snapshot, conversations: conversations, reply: reply)
            default:
                reply.failure("Pass exactly one file path, attachment ID, or transfer ID", code: -32602)
            }
        } catch {
            Log.session.warning("HostFileDownload.failed request=\(reply.id)")
            reply.failure(error.localizedDescription)
        }
    }

    private func send(_ snapshot: Snapshot, conversations: ConversationManager, reply: OxHostRPC.Reply) throws {
        guard StorageRoot.currentScope == snapshot.scope,
              conversations.debugSession(matching: snapshot.conversationID.uuidString) != nil else {
            throw RuntimeError.bridge("The download conversation is no longer available")
        }
        if let grantID = snapshot.grantID {
            _ = try DeviceFolderStore.shared.requireGrant(grantID, profileId: snapshot.scope.profileID)
        }
        let end = min(snapshot.offset + 512 * 1024, snapshot.data.count)
        let data = snapshot.data[snapshot.offset..<end].base64EncodedString()
        if end == snapshot.data.count {
            state = .idle
            Log.session.info("HostFileDownload.complete conversation=\(snapshot.conversationID) bytes=\(end)")
        } else {
            var remaining = snapshot
            remaining.offset = end
            state = .sending(remaining)
        }
        reply.success(JSONValue.object([
            "transferId": .string(snapshot.id.uuidString), "offset": .int(snapshot.offset),
            "size": .int(snapshot.data.count), "data": .string(data),
        ]))
    }
}
