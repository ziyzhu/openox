import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class ChatComposerModel {
    struct SlashInvocation {
        let skill: Skill
        let command: String
        let argument: String
    }

    enum Surface: Equatable {
        case none
        case attachments
        case mention(String)
        case slash(String)
    }

    struct Message {
        let id: UUID
        let text: String
        let attachments: [Artifact]
    }

    struct PendingAttachment: Identifiable, Equatable {
        let id: UUID
        let displayName: String
    }

    enum DraftAttachment: Identifiable, Equatable {
        enum ID: Hashable {
            case operation(UUID)
            case artifact(String)
        }

        case importing(PendingAttachment)
        case ready(Artifact)

        var id: ID {
            switch self {
            case .importing(let pending): .operation(pending.id)
            case .ready(let artifact): .artifact(artifact.id)
            }
        }
    }

    var attributedDraft = AttributedString()
    private(set) var draftAttachments: [DraftAttachment] = []
    private(set) var draftID = UUID()
    private(set) var caretEndRequest = 0
    private var attachmentMenuPresented = false
    private var stopControlTransition: UUID?
    private var activePasteboardChangeCount: Int?
    @ObservationIgnored private var importTasks: [UUID: Task<Void, Never>] = [:]

    deinit {
        for task in importTasks.values {
            task.cancel()
        }
    }

    var draft: String {
        get { String(attributedDraft.characters) }
        set { attributedDraft = AttributedString(newValue) }
    }

    var isEmpty: Bool {
        draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && draftAttachments.isEmpty
    }

    var canSubmit: Bool {
        !draftAttachments.contains { if case .ready = $0 { false } else { true } }
            && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !draftAttachments.isEmpty)
    }

    var isImporting: Bool {
        draftAttachments.contains { if case .importing = $0 { true } else { false } }
    }

    var suppressesStopControl: Bool {
        stopControlTransition != nil
    }

    var slashSuggestions: [Skill] {
        guard case .slash(let query) = surface else { return [] }
        let needle = query.lowercased()
        return Skills.shared.all.filter {
            needle.isEmpty || $0.name.lowercased().contains(needle)
        }
    }

    var slashInvocation: SlashInvocation? {
        slashInvocation(in: draft)
    }

    var surface: Surface {
        if attachmentMenuPresented { return .attachments }
        if let mention = activeMention { return .mention(mention) }
        if let slash = activeSlash { return .slash(slash) }
        return .none
    }

    private var activeMention: String? {
        guard let at = draft.lastIndex(of: "@") else { return nil }
        if at > draft.startIndex, !draft[draft.index(before: at)].isWhitespace { return nil }
        let token = draft[draft.index(after: at)...]
        guard !token.contains(where: \.isWhitespace) else { return nil }
        return String(token)
    }

    private var activeSlash: String? {
        guard draft.first == "/" else { return nil }
        let token = draft.dropFirst()
        guard !token.contains(where: \.isWhitespace) else { return nil }
        return String(token)
    }

    func startMention() {
        attachmentMenuPresented = false
        if activeMention == nil {
            draft += draft.isEmpty || draft.last?.isWhitespace == true ? "@" : " @"
        }
        caretEndRequest += 1
    }

    func appendDictation(_ text: String) {
        let separator = draft.isEmpty || draft.last?.isWhitespace == true ? "" : " "
        attributedDraft.append(AttributedString(separator + text))
        caretEndRequest += 1
    }

    func finishMention() {
        guard let at = draft.lastIndex(of: "@") else { return }
        draft = String(draft[..<at])
    }

    func slashInvocation(in draft: String) -> SlashInvocation? {
        guard draft.first == "/" else { return nil }
        let commandEnd = draft.firstIndex(where: \.isWhitespace) ?? draft.endIndex
        let nameStart = draft.index(after: draft.startIndex)
        let name = String(draft[nameStart..<commandEnd])
        guard let skill = Skills.shared.all.first(where: {
            $0.name.caseInsensitiveCompare(name) == .orderedSame
        }) else { return nil }
        return SlashInvocation(
            skill: skill,
            command: String(draft[..<commandEnd]),
            argument: String(draft[commandEnd...]).trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    func delayStopControl() {
        let transition = UUID()
        stopControlTransition = transition
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard self?.stopControlTransition == transition else { return }
            self?.stopControlTransition = nil
        }
    }

    func takeMessage() -> Message? {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSubmit else { return nil }
        let attachments = draftAttachments.compactMap { item -> Artifact? in
            if case .ready(let artifact) = item { artifact } else { nil }
        }
        let message = Message(id: draftID, text: text, attachments: attachments)
        draft = ""
        draftAttachments = []
        attachmentMenuPresented = false
        draftID = UUID()
        return message
    }

    func setAttachmentMenuPresented(_ presented: Bool) {
        attachmentMenuPresented = presented
    }

    func claimPasteboardChange(_ changeCount: Int) -> Bool {
        guard activePasteboardChangeCount != changeCount else { return false }
        activePasteboardChangeCount = changeCount
        DispatchQueue.main.async { [weak self] in
            guard self?.activePasteboardChangeCount == changeCount else { return }
            self?.activePasteboardChangeCount = nil
        }
        return true
    }

    func importAttachment(
        named displayName: String,
        operation: @escaping @MainActor () async throws -> Artifact,
        onFailure: @escaping @MainActor (Error) -> Void
    ) {
        let pending = PendingAttachment(id: UUID(), displayName: displayName)
        let importingDraftID = draftID
        draftAttachments.append(.importing(pending))
        Log.ui.info("ChatComposer.import begin draft=\(importingDraftID) import=\(pending.id) name=\(displayName)")
        importTasks[pending.id] = Task { [weak self] in
            do {
                let artifact = try await operation()
                guard !Task.isCancelled else { return }
                self?.finishImport(pending.id, draftID: importingDraftID, artifact: artifact)
            } catch is CancellationError {
                self?.cancelImport(pending.id, draftID: importingDraftID)
            } catch {
                guard let self else { return }
                self.failImport(pending.id, draftID: importingDraftID, error: error)
                onFailure(error)
            }
        }
    }

    func attachArtifact(_ artifact: Artifact) {
        guard !draftAttachments.contains(where: { $0.id == .artifact(artifact.id) }) else {
            Log.ui.info("ChatComposer.attachment duplicate draft=\(draftID) artifact=\(artifact.id)")
            return
        }
        draftAttachments.append(.ready(artifact))
        Log.ui.info("ChatComposer.attachment artifact draft=\(draftID) artifact=\(artifact.id)")
    }

    var draftArtifactIDs: Set<String> {
        Set(draftAttachments.compactMap { item in
            if case .artifact(let id) = item.id { id } else { nil }
        })
    }

    func removeDraftAttachment(_ item: DraftAttachment) {
        draftAttachments.removeAll { $0.id == item.id }
        if case .operation(let id) = item.id { importTasks.removeValue(forKey: id)?.cancel() }
        Log.ui.info("ChatComposer.attachment remove draft=\(draftID) item=\(item.id)")
    }

    private func finishImport(_ id: UUID, draftID importingDraftID: UUID, artifact: Artifact) {
        importTasks.removeValue(forKey: id)
        guard draftID == importingDraftID else {
            draftAttachments.removeAll { $0.id == .operation(id) }
            Log.ui.info("ChatComposer.import stale draft=\(importingDraftID) current=\(draftID) import=\(id)")
            return
        }
        guard let index = draftAttachments.firstIndex(where: { $0.id == .operation(id) }) else { return }
        draftAttachments[index] = .ready(artifact)
        Log.ui.info("ChatComposer.import ready draft=\(draftID) import=\(id) artifact=\(artifact.id)")
    }

    private func cancelImport(_ id: UUID, draftID importingDraftID: UUID) {
        importTasks.removeValue(forKey: id)
        draftAttachments.removeAll { $0.id == .operation(id) }
        Log.ui.info("ChatComposer.import cancelled draft=\(importingDraftID) import=\(id)")
    }

    private func failImport(_ id: UUID, draftID importingDraftID: UUID, error: Error) {
        importTasks.removeValue(forKey: id)
        guard draftID == importingDraftID,
              draftAttachments.contains(where: { $0.id == .operation(id) }) else { return }
        draftAttachments.removeAll { $0.id == .operation(id) }
        Log.ui.error("ChatComposer.import failed draft=\(importingDraftID) import=\(id) error=\(error.localizedDescription)")
    }
}

enum AttachmentChoice {
    case camera
    case photos
    case files
    case artifacts
    case service(Service)
}
