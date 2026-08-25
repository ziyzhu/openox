import Foundation

nonisolated enum A11yID {
    enum Startup {
        static let status = "startup.status"
    }

    enum Onboarding {
        static let pagination = "onboarding.pagination"
        static let websitesDemo = "onboarding.websitesDemo"
        static let chooseAI = "onboarding.chooseAI"
        static let continueToDisclaimer = "onboarding.continueToDisclaimer"
        static let discord = "onboarding.discord"
        static let github = "onboarding.github"
        static let complete = "onboarding.complete"
    }

    enum NotificationSetup {
        static let permission = "notifications.permission"
    }

    enum SkillImport {
        static let preview = "skillImport.preview"
        static let cancel = "skillImport.cancel"
        static let add = "skillImport.add"
        static let replace = "skillImport.replace"
        static let copy = "skillImport.copy"
    }

    enum ChatImport {
        static let preview = "chatImport.preview"
        static let cancel = "chatImport.cancel"
        static let add = "chatImport.add"
    }

    enum SiriSetup {
        static let guide = "siri.guide"
    }

    enum Sidebar {
        static let panel = "sidebar.panel"
        static let close = "sidebar.close"
        static let newChat = "sidebar.newChat"
        static let settings = "sidebar.settings"
        static let services = "sidebar.services"
        static let artifacts = "sidebar.artifacts"
        static let skills = "sidebar.skills"
        static func row(_ sessionId: String) -> String { "sidebar.row.\(sessionId)" }
        static func deleteRow(_ sessionId: String) -> String { "sidebar.deleteRow.\(sessionId)" }
        static func renameRow(_ sessionId: String) -> String { "sidebar.renameRow.\(sessionId)" }
        static func favoriteRow(_ sessionId: String) -> String { "sidebar.favoriteRow.\(sessionId)" }
    }

    enum Artifacts {
        static let ready = "artifacts.ready"
        static let transitioning = "artifacts.transitioning"
        static let search = "artifacts.search"
        static let filterAndSort = "artifacts.filterAndSort"
        static let add = "artifacts.add"
        static let addFiles = "artifacts.add.files"
        static let addPhotos = "artifacts.add.photos"
        static let addCamera = "artifacts.add.camera"
        static let previewDismiss = "artifacts.preview.dismiss"
        static let renameSubmit = "artifacts.rename.submit"
        static let deleteConfirm = "artifacts.delete.confirm"
        static func item(_ id: String) -> String { "artifacts.item.\(id)" }
        static func filter(_ id: String) -> String { "artifacts.filter.\(id)" }
        static func save(_ id: String) -> String { "artifacts.save.\(id)" }
        static func share(_ id: String) -> String { "artifacts.share.\(id)" }
        static func rename(_ id: String) -> String { "artifacts.rename.\(id)" }
        static func delete(_ id: String) -> String { "artifacts.delete.\(id)" }
    }

    enum Settings {
        static let close = "settings.close"
        static let soul = "settings.soul"
        static let soulEditor = "settings.soulEditor"
        static let soulSave = "settings.soulSave"
        static let soulCopy = "settings.soulCopy"
        static let defaultModel = "settings.defaultModel"
        static let customProviders = "settings.customProviders"
        static let customProviderAdd = "settings.customProviderAdd"
        static let customProviderName = "settings.customProviderName"
        static let customProviderURL = "settings.customProviderURL"
        static let customProviderKey = "settings.customProviderKey"
        static let customProviderSave = "settings.customProviderSave"
        static let customProviderDelete = "settings.customProviderDelete"
        static func customProvider(_ id: String) -> String { "settings.customProvider.\(id)" }
        static func customProviderModel(_ id: String) -> String { "settings.customProviderModel.\(id)" }
        static let language = "settings.language"
        static let voice = "settings.voice"
        static let voiceAutomatic = "settings.voice.automatic"
        static let voiceAutomaticPreview = "settings.voice.automatic.preview"
        static func voiceOption(_ identifier: String) -> String { "settings.voice.option.\(identifier)" }
        static func voicePreview(_ identifier: String) -> String { "settings.voice.preview.\(identifier)" }
        static let theme = "settings.theme"
        static let memory = "settings.memory"
        static let memoryEditor = "settings.memoryEditor"
        static let memorySave = "settings.memorySave"
        static let memoryCopy = "settings.memoryCopy"
        static let skillCreate = "settings.skillCreate"
        static let skillName = "settings.skillName"
        static let skillDescription = "settings.skillDescription"
        static let skillInstructions = "settings.skillInstructions"
        static let skillSave = "settings.skillSave"
        static let skillAddService = "settings.skillAddService"
        static let skillServicesLoading = "settings.skillServicesLoading"
        static func skillService(_ domain: String) -> String { "settings.skillService.\(domain)" }
        static func skillServiceRemove(_ domain: String) -> String { "settings.skillServiceRemove.\(domain)" }
        static func skillRow(_ name: String) -> String { "settings.skill.\(name)" }
        static func skillShare(_ name: String) -> String { "settings.skillShare.\(name)" }
        static func skillDelete(_ name: String) -> String { "settings.skillDelete.\(name)" }
        static let storeICloud = "settings.storeICloud"
        static let storeStatus = "settings.storeStatus"
        static let activeProfile = "settings.activeProfile"
        static let profileDetail = "settings.profileDetail"
        static let profileSelection = "settings.profileSelection"
        static let profileAdd = "settings.profileAdd"
        static let profileCreate = "settings.profileCreate"
        static let profileOpen = "settings.profileOpen"
        static func profileRow(_ id: String) -> String { "settings.profile.\(id)" }
        static func profileRename(_ id: String) -> String { "settings.profileRename.\(id)" }
        static func profileMove(_ id: String) -> String { "settings.profileMove.\(id)" }
        static func profileDuplicate(_ id: String) -> String { "settings.profileDuplicate.\(id)" }
        static func profileDelete(_ id: String) -> String { "settings.profileDelete.\(id)" }
        static let server = "settings.server"
        static let logs = "settings.logs"
        static let discord = "settings.discord"
        static let github = "settings.github"
        static let howItWorks = "settings.howItWorks"
        static let siri = "settings.siri"
        static let notifications = "settings.notifications"
        static let serverField = "settings.serverField"
        static let serverSync = "settings.serverSync"
        static let serverStatus = "settings.serverStatus"
        static let repositoryAdd = "settings.repositoryAdd"
        static let repositoryURL = "settings.repositoryURL"
        static let repositoryInstall = "settings.repositoryInstall"
        static let repositoryStatus = "settings.repositoryStatus"
        static func repository(_ id: String) -> String { "settings.repository.\(id)" }
        static func repositoryEnabled(_ id: String) -> String { "settings.repositoryEnabled.\(id)" }
        static func repositoryUpdate(_ id: String) -> String { "settings.repositoryUpdate.\(id)" }
        static func repositoryRemove(_ id: String) -> String { "settings.repositoryRemove.\(id)" }
        static func conflict(_ id: String) -> String { "settings.repositoryConflict.\(id)" }
        static func conflictCandidate(_ id: String, _ repositoryID: String) -> String {
            "settings.repositoryConflict.\(id).\(repositoryID)"
        }
    }

    enum Chat {
        static let toast = "chat.toast"
        static let more = "chat.more"
        static let attach = "chat.attach"
        static let input = "chat.input"
        static let send = "chat.send"
        static let stop = "chat.stop"
        static let activity = "chat.activity"
        static let scrollToBottom = "chat.scrollToBottom"
        static let openSidebar = "chat.openSidebar"
        static let delete = "chat.delete"
        static let export = "chat.export"
        static let modelPicker = "chat.modelPicker"
        static let modelRegion = "chat.modelRegion"
        static let modelProvider = "chat.modelProvider"
        static func modelProviderOption(_ clientId: String) -> String { "chat.modelProviderOption.\(clientId)" }
        static let modelSelection = "chat.modelSelection"
        static let modelAuthAPIKey = "chat.modelAuth.apiKey"
        static let modelAuthOAuth = "chat.modelAuth.oauth"
        static let modelAuthNone = "chat.modelAuth.none"
        static let modelSave = "chat.modelSave"
        static let modelCustomProviders = "chat.modelCustomProviders"
        static let modelClose = "chat.modelClose"
        static let temporaryToggle = "chat.temporaryToggle"
        static let temporaryEmpty = "chat.temporaryEmpty"
        static let persistedEmpty = "chat.persistedEmpty"
        static let newActions = "chat.newActions"
        static let newActionsService = "chat.newActions.service"
        static let newActionsFeatures = "chat.newActions.features"
        static let newWorkflows = "chat.newWorkflows"
        static let newWorkflowServices = "chat.newWorkflow.services"
        static let newWorkflowOutcome = "chat.newWorkflow.outcome"
        static func modelOption(_ modelId: String) -> String { "chat.modelOption.\(modelId)" }
        static func modelKey(_ clientId: String) -> String { "chat.modelKey.\(clientId)" }
        static func modelKeySignIn(_ clientId: String) -> String { "chat.modelKeySignIn.\(clientId)" }
        static let modelKeySignInError = "chat.modelKeySignInError"
        static let modelKeyNotice = "chat.modelKeyNotice"
        static let modelKeyField = "chat.modelKeyField"
        static let modelKeyRemove = "chat.modelKeyRemove"
        static let modelKeyWebsite = "chat.modelKeyWebsite"
        static let mentionLoading = "chat.mention.loading"

        enum HTMLArtifact {
            static let dismiss = "chat.htmlArtifact.dismiss"
        }

        enum MarkdownArtifact {
            static let dismiss = "chat.markdownArtifact.dismiss"
            static let edit = "chat.markdownArtifact.edit"
            static let editor = "chat.markdownArtifact.editor"
            static let save = "chat.markdownArtifact.save"
        }

        enum Artifact {
            static let open = "chat.artifact.open"
            static let list = "chat.artifact.list"
            static let done = "chat.artifact.done"
            static func item(_ filename: String) -> String { "chat.artifact.item.\(filename)" }
        }

        enum ArtifactPicker {
            static let list = "chat.artifactPicker.list"
            static let attach = "chat.artifactPicker.attach"
            static let cancel = "chat.artifactPicker.cancel"
            static let empty = "chat.artifactPicker.empty"
            static func item(_ filename: String) -> String { "chat.artifactPicker.item.\(filename)" }
        }

        enum Message {
            static let user = "chat.message.user"
            static let agent = "chat.message.agent"
            static let copy = "chat.message.copy"
            static let share = "chat.message.share"
            static let readAloud = "chat.message.readAloud"
            static let branch = "chat.message.branch"
            static let retry = "chat.message.retry"
            static let contextCompaction = "chat.contextCompacted"
            static func artifact(_ artifactId: String) -> String { "chat.message.artifact.\(artifactId)" }
            static func serviceInspector(_ domain: String) -> String { "chat.message.serviceInspector.\(domain)" }
            static func skill(_ name: String) -> String { "chat.message.skill.\(name)" }
            static func shoveler(_ blockId: String) -> String { "chat.message.shoveler.\(blockId)" }
            static let videoPlay = "chat.message.video.play"
        }

        enum Attach {
            static let camera = "chat.attach.camera"
            static let photos = "chat.attach.photos"
            static let files = "chat.attach.files"
            static let artifacts = "chat.attach.artifacts"
            static let services = "chat.attach.services"
            static let explore = "chat.attach.explore"
            static let exploreBack = "chat.attach.exploreBack"
            static let servicesLoading = "chat.attach.servicesLoading"
            static let filter = "chat.attach.filter"
            static let connectMCP = "chat.attach.connectMCP"
            static func catalogMCP(_ id: String) -> String { "chat.attach.catalogMCP.\(id)" }
            static func mcpConnecting(_ id: String) -> String { "chat.attach.mcpConnecting.\(id)" }
            static func retryMCP(_ id: String) -> String { "chat.attach.retryMCP.\(id)" }
            static let mcpEndpoint = "chat.attach.mcpEndpoint"
            static func startChat(_ domain: String) -> String { "chat.attach.startChat.\(domain)" }
            static func save(_ domain: String) -> String { "chat.attach.save.\(domain)" }
            static func service(_ domain: String) -> String { "chat.attach.service.\(domain)" }
            static func domain(_ domain: String) -> String { "chat.attach.domain.\(domain)" }
            static func signIn(_ domain: String) -> String { "chat.attach.signIn.\(domain)" }
            static func signInProgress(_ domain: String) -> String { "chat.attach.signInProgress.\(domain)" }
            static func botControl(_ domain: String) -> String { "chat.attach.botControl.\(domain)" }
            static func payment(_ domain: String) -> String { "chat.attach.payment.\(domain)" }
            static func signOut(_ domain: String) -> String { "chat.attach.signOut.\(domain)" }
            static func signOutProgress(_ domain: String) -> String { "chat.attach.signOutProgress.\(domain)" }
            static func inspectPage(_ domain: String) -> String { "chat.attach.inspectPage.\(domain)" }
            static func clearWebData(_ domain: String) -> String { "chat.attach.clearWebData.\(domain)" }
            static func deleteLocalService(_ domain: String) -> String { "chat.attach.deleteLocalService.\(domain)" }
            static func disconnectMCP(_ domain: String) -> String { "chat.attach.disconnectMCP.\(domain)" }
            static func repository(_ domain: String) -> String { "chat.attach.repository.\(domain)" }
            static func attach(_ domain: String) -> String { "chat.attach.attach.\(domain)" }
            static func remove(_ domain: String) -> String { "chat.attach.remove.\(domain)" }
            static func action(_ id: String) -> String { "chat.attach.action.\(id)" }
            static func actionApproval(_ id: String) -> String { "chat.attach.actionApproval.\(id)" }
            static let deviceFilesAdd = "chat.attach.deviceFiles.add"
            static func deviceFilesRemove(_ id: String) -> String { "chat.attach.deviceFiles.remove.\(id)" }
            static func devicePermission(_ id: String) -> String { "chat.attach.devicePermission.\(id)" }
        }

        static func servicePill(_ domain: String) -> String { "chat.servicePill.\(domain)" }
        static func composerAttachment(_ filename: String) -> String { "chat.composerAttachment.\(filename)" }
        static func mention(_ domain: String) -> String { "chat.mention.\(domain)" }
        static func skill(_ name: String) -> String { "chat.skill.\(name)" }

        static func permissionRequest(_ icon: String) -> String { "chat.permissionRequest.\(icon)" }
        static func step(_ icon: String) -> String { "chat.step.\(icon)" }
        static let permissionAcknowledgement = "chat.permissionAcknowledgement"
        static let choiceAcknowledgement = "chat.choiceAcknowledgement"
        static let choiceCustomInput = "chat.choice.customInput"
        static let choiceCustomSubmit = "chat.choice.customSubmit"
        static func confirm(_ option: String) -> String { "chat.confirm.\(option)" }
        static func confirmReceipt(_ option: String) -> String { "chat.confirm.receipt.\(option)" }
    }

    enum Logs {
        static let reload = "logs.reload"
        static let copy = "logs.copy"
        static let export = "logs.export"
        static let clear = "logs.clear"
    }

    enum ServiceHandoff {
        static let back = "serviceHandoff.back"
        static let forward = "serviceHandoff.forward"
        static let done = "serviceHandoff.done"
    }

    enum ServiceBrowser {
        static let back = "serviceBrowser.back"
        static let forward = "serviceBrowser.forward"
        static let reloadOrStop = "serviceBrowser.reloadOrStop"
        static let share = "serviceBrowser.share"
        static let openInSafari = "serviceBrowser.openInSafari"
        static let done = "serviceBrowser.done"
    }

    enum ServiceInspector {
        static let address = "serviceInspector.address"
        static let close = "serviceInspector.close"
    }
}

enum A11yLabel {
    static var back: String { L10n.string("Back", comment: "") }
    static var forward: String { L10n.string("Forward", comment: "") }
    static var more: String { L10n.string("More", comment: "") }
    static var send: String { L10n.string("Send", comment: "") }
    static var stop: String { L10n.string("Stop", comment: "") }
    static var addAttachment: String { L10n.string("Add attachment", comment: "") }
    static var newChat: String { L10n.string("New chat", comment: "") }
    static var settings: String { L10n.string("Settings", comment: "") }
    static var deleteChat: String { L10n.string("Delete chat", comment: "") }
    static var renameChat: String { L10n.string("Rename chat", comment: "") }
    static var pin: String { L10n.string("Pin", comment: "") }
    static var unpin: String { L10n.string("Unpin", comment: "") }
    static var services: String { L10n.string("Services", comment: "") }
    static var artifacts: String { L10n.string("Artifacts", comment: "") }
    static var skills: String { L10n.string("Skills", comment: "") }
    static var openSidebar: String { L10n.string("Open chat history", comment: "") }
    static var searchChats: String { L10n.string("Search chats", comment: "") }
    static var closeChatHistory: String { L10n.string("Close chat history", comment: "") }
    static var scrollToBottom: String { L10n.string("Scroll to bottom", comment: "") }
    static var copyMessage: String { L10n.string("Copy message", comment: "") }
    static var shareMessage: String { L10n.string("Share message", comment: "") }
    static var readAloud: String { L10n.string("Read aloud", comment: "") }
    static var stopReading: String { L10n.string("Stop reading", comment: "") }
    static var shareArtifact: String { L10n.string("Share artifact", comment: "") }
    static var copyCode: String { L10n.string("Copy code", comment: "") }
    static var branchMessage: String { L10n.string("Branch from this reply", comment: "") }
    static var retryMessage: String { L10n.string("Regenerate reply", comment: "") }
    static var reloadLogs: String { L10n.string("Reload logs", comment: "") }
    static var copyLogs: String { L10n.string("Copy logs", comment: "") }
    static var clearLogs: String { L10n.string("Clear logs", comment: "") }
    static var editKey: String { L10n.string("Edit API key", comment: "") }

    static func remove(_ name: String) -> String { String(format: L10n.string("Remove %@", comment: ""), name) }
}
