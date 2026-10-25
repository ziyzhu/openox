import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class ConversationComposerModel {
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
        let attachments: [FileItem]
    }

    struct PendingAttachment: Identifiable, Equatable {
        let id: UUID
        let displayName: String
    }

    enum DraftAttachment: Identifiable, Equatable {
        enum ID: Hashable {
            case operation(UUID)
            case file(String)
        }

        case importing(PendingAttachment)
        case ready(FileItem)
        case staged(FileImporter.StagedFile)

        var file: FileItem? {
            switch self {
            case .importing: nil
            case .ready(let file): file
            case .staged(let source): source.file
            }
        }

        var id: ID {
            switch self {
            case .importing(let pending): .operation(pending.id)
            case .ready(let file): .file(file.id)
            case .staged(let source): .file(source.file.id)
            }
        }
    }

    private enum Submission {
        case editing
        case publishing
    }

    private var submission = Submission.editing
    var isPublishing: Bool { submission == .publishing }

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
        !isImporting
            && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !draftAttachments.isEmpty)
    }

    var isImporting: Bool {
        isPublishing || draftAttachments.contains { if case .importing = $0 { true } else { false } }
    }

    var suppressesStopControl: Bool {
        stopControlTransition != nil
    }

    var slashSuggestions: [Skill] {
        guard case .slash(let query) = surface else { return [] }
        let needle = query.lowercased()
        return Skills.shared.userFacing.filter {
            needle.isEmpty || $0.name.lowercased().contains(needle)
        }
    }

    var websiteSuggestion: URL? {
        guard surface == .none, draftAttachments.isEmpty else { return nil }
        let value = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.contains("://") || value.range(of: #"^[^/?#]+\.[a-z]{2,}(?:[/?#].*)?$"#, options: [.regularExpression, .caseInsensitive]) != nil else { return nil }
        return WebBrowserView.url(from: value)
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

    func replaceDraft(_ text: String) {
        draft = text
        caretEndRequest += 1
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
        guard let skill = Skills.shared.userFacing.first(where: {
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

    func takeMessage(in conversation: Conversation) async throws -> Message? {
        guard canSubmit else { return nil }
        submission = .publishing
        defer { submission = .editing }
        let staged = draftAttachments.compactMap { item -> FileImporter.StagedFile? in
            if case .staged(let file) = item { file } else { nil }
        }
        let published = staged.isEmpty ? [] : try await conversation.importAttachments(staged)
        var remaining = published.makeIterator()
        let attachments = draftAttachments.compactMap { item -> FileItem? in
            switch item {
            case .importing: nil
            case .ready(let file): file
            case .staged: remaining.next()
            }
        }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let message = Message(id: draftID, text: text, attachments: attachments)
        clearDraft()
        return message
    }

    func discardDraft() {
        guard !isPublishing else { return }
        clearDraft()
    }

    private func clearDraft() {
        for task in importTasks.values { task.cancel() }
        importTasks.removeAll()
        for item in draftAttachments {
            if case .staged(let source) = item { source.discard() }
        }
        draft = ""
        draftAttachments = []
        attachmentMenuPresented = false
        draftID = UUID()
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

    func attach(_ files: [FileImporter.StagedFile]) {
        draftAttachments.append(contentsOf: files.map(DraftAttachment.staged))
    }

    func importAttachment(
        named displayName: String,
        operation: @escaping @MainActor () async throws -> FileImporter.StagedFile,
        onFailure: @escaping @MainActor (Error) -> Void
    ) {
        let pending = PendingAttachment(id: UUID(), displayName: displayName)
        let importingDraftID = draftID
        draftAttachments.append(.importing(pending))
        Log.ui.info("ConversationComposer.import begin draft=\(importingDraftID) import=\(pending.id) name=\(displayName)")
        importTasks[pending.id] = Task { [weak self] in
            do {
                let file = try await operation()
                guard !Task.isCancelled else { file.discard(); return }
                self?.finishImport(pending.id, draftID: importingDraftID, file: file)
            } catch is CancellationError {
                self?.cancelImport(pending.id, draftID: importingDraftID)
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.failImport(pending.id, draftID: importingDraftID, error: error)
                onFailure(error)
            }
        }
    }

    func removeDraftAttachment(_ item: DraftAttachment) {
        guard !isPublishing else { return }
        if case .staged(let source) = item { source.discard() }
        draftAttachments.removeAll { $0.id == item.id }
        if case .operation(let id) = item.id { importTasks.removeValue(forKey: id)?.cancel() }
        Log.ui.info("ConversationComposer.attachment remove draft=\(draftID) item=\(item.id)")
    }

    private func finishImport(_ id: UUID, draftID importingDraftID: UUID, file: FileImporter.StagedFile) {
        importTasks.removeValue(forKey: id)
        guard draftID == importingDraftID else {
            draftAttachments.removeAll { $0.id == .operation(id) }
            Log.ui.info("ConversationComposer.import stale draft=\(importingDraftID) current=\(draftID) import=\(id)")
            return
        }
        guard let index = draftAttachments.firstIndex(where: { $0.id == .operation(id) }) else { return }
        draftAttachments[index] = .staged(file)
        Log.ui.info("ConversationComposer.import ready draft=\(draftID) import=\(id) file=\(file.file.id)")
    }

    private func cancelImport(_ id: UUID, draftID importingDraftID: UUID) {
        importTasks.removeValue(forKey: id)
        draftAttachments.removeAll { $0.id == .operation(id) }
        Log.ui.info("ConversationComposer.import cancelled draft=\(importingDraftID) import=\(id)")
    }

    private func failImport(_ id: UUID, draftID importingDraftID: UUID, error: Error) {
        importTasks.removeValue(forKey: id)
        guard draftID == importingDraftID,
              draftAttachments.contains(where: { $0.id == .operation(id) }) else { return }
        draftAttachments.removeAll { $0.id == .operation(id) }
        Log.ui.error("ConversationComposer.import failed draft=\(importingDraftID) import=\(id) error=\(error.localizedDescription)")
    }
}

enum AttachmentChoice {
    case camera
    case photos
    case files
    case website
    case service(Service)
}
