import Foundation

nonisolated enum Actions {
    static let chatDelete = "ox.chat.delete"
    static let providerDefault = "ox.provider.default"
    static let providerList = "ox.provider.list"
    static let providerGet = "ox.provider.get"
    static let providerValidate = "ox.provider.validate"
    static let providerSave = "ox.provider.save"
    static let providerDelete = "ox.provider.delete"
    static let providerAuthenticate = "ox.provider.authenticate"
    static let providerDeauthenticate = "ox.provider.deauthenticate"
    static let providerConnect = "ox.provider.connect"
    static let secretList = "ox.secret.list"
    static let secretAdd = "ox.secret.add"
    static let secretDelete = "ox.secret.delete"
    static let appInfo = "ox.app.info"
    static let appProfile = "ox.app.profile"
    static let appProfiles = "ox.app.profiles"
    static let appNotifications = "ox.app.notifications"
    static let appLanguage = "ox.app.language"
    static let appTheme = "ox.app.theme"
    static let appVoice = "ox.app.voice"
    static let appVoiceOptions = "ox.app.voiceOptions"
    static let appModel = "ox.app.model"
    static let appDefaultModel = "ox.app.defaultModel"
    static let appActionPolicies = "ox.app.actionPolicies"
    static let appRepositories = "ox.app.repositories"
    static let appLogs = "ox.app.logs"
    static let appRenameChat = "ox.app.renameChat"
    static let webSearch = "ox.web.search"
    static let webFetch = "ox.web.fetch"
    static let fsList = "ox.fs.list"
    static let fsRead = "ox.fs.read"
    static let outputRead = "ox.output.read"
    static let fsWrite = "ox.fs.write"
    static let fsEdit = "ox.fs.edit"
    static let fsDelete = "ox.fs.delete"
    static let fsGlob = "ox.fs.glob"
    static let fsGrep = "ox.fs.grep"
    static let artifactAttach = "ox.artifact.attach"
    static let serviceFind = "ox.service.find"
    static let serviceListAttached = "ox.service.listAttached"
    static let serviceInspect = "ox.service.inspect"
    static let serviceValidate = "ox.service.validate"
    static let serviceCreate = "ox.service.create"
    static let serviceUpdate = "ox.service.update"
    static let serviceCopy = "ox.service.copy"
    static let serviceDelete = "ox.service.delete"
    static let repositoryConnect = "ox.repository.connect"
    static let repositorySync = "ox.repository.sync"
    static let repositoryDisconnect = "ox.repository.disconnect"
    static let repositoryPropose = "ox.repository.propose"
    static let repositoryGitStatus = "ox.repository.git.status"
    static let repositoryGitLog = "ox.repository.git.log"
    static let repositoryGitShow = "ox.repository.git.show"
    static let repositoryGitDiff = "ox.repository.git.diff"
    static let repositoryGitCheckout = "ox.repository.git.checkout"
    static let repositoryGitCommit = "ox.repository.git.commit"
    static let repositoryGitRevert = "ox.repository.git.revert"
    static let repositoryGitRestore = "ox.repository.git.restore"
    static let serviceAttach = "ox.service.attach"
    static let serviceSignIn = "ox.service.signIn"
    static let serviceSolve = "ox.service.solve"
    static let servicePayment = "ox.service.pay"
    static let serviceDetach = "ox.service.detach"
    static let skillShare = "ox.skill.share"
    static let skillCreate = "ox.skill.create"
    static let skillCopy = "ox.skill.copy"
    static let skillDelete = "ox.skill.delete"
    static let scheduleCreate = "ox.schedule.create"
    static let scheduleList = "ox.schedule.list"
    static let scheduleDelete = "ox.schedule.delete"
    static let scheduleEnable = "ox.schedule.enable"
    static let scheduleRun = "ox.schedule.run"
    static let memoryRead = "ox.memory.read"
    static let memoryWrite = "ox.memory.write"
    static let memoryReplaceText = "ox.memory.replaceText"
    static let artifactList = "ox.artifact.list"
    static let artifactImport = "ox.artifact.import"
    static let artifactWrite = "ox.artifact.write"
    static let artifactReplaceText = "ox.artifact.replaceText"
    static let artifactRename = "ox.artifact.rename"
    static let artifactDelete = "ox.artifact.delete"
    static let artifactPresent = "ox.artifact.present"
    static let widgetShoveler = "ox.widget.shoveler"
    static let widgetVideo = "ox.widget.video"
    static let userChoose = "ox.user.choose"
    static let userFollow = "ox.user.follow"
    static let userReportProgress = "ox.user.reportProgress"

    static let builtIn = [
        chatDelete, providerDefault, providerList, providerGet, providerValidate, providerSave, providerDelete,
        providerAuthenticate, providerDeauthenticate, providerConnect, secretList, secretAdd, secretDelete,
        appInfo, appProfile, appProfiles, appNotifications, appLanguage, appTheme, appVoice,
        appVoiceOptions, appModel, appDefaultModel, appActionPolicies, appRepositories,
        appLogs, appRenameChat,
        webSearch, webFetch,
    ] + BrowserFunctionCatalog.actionNames + [
        fsList, fsRead, outputRead, fsWrite, fsEdit, fsDelete, fsGlob, fsGrep,
        artifactAttach,
        serviceFind, serviceListAttached, serviceInspect, serviceValidate, serviceCreate,
        serviceUpdate, serviceCopy, serviceDelete, repositoryConnect, repositorySync, repositoryDisconnect,
        repositoryPropose,
        repositoryGitStatus, repositoryGitLog,
        repositoryGitShow, repositoryGitDiff, repositoryGitCheckout, repositoryGitCommit, repositoryGitRevert,
        repositoryGitRestore, serviceAttach, serviceSignIn, serviceSolve, servicePayment, serviceDetach,
        skillCreate, skillCopy, skillDelete, skillShare,
        scheduleCreate, scheduleList, scheduleDelete, scheduleEnable, scheduleRun,
        memoryRead, memoryWrite, memoryReplaceText,
        artifactList, artifactImport, artifactWrite, artifactReplaceText, artifactRename,
        artifactDelete, artifactPresent,
        widgetShoveler, widgetVideo, userChoose, userFollow, userReportProgress,
    ]

    static func defaultPolicy(for action: String) -> ActionPolicy {
        guard builtIn.contains(action) else { return .ask }
        return action.hasSuffix(".delete") ? .ask : .allow
    }

    static func label(for action: String) -> String? {
        if let browser = BrowserFunctionCatalog.action(named: action) {
            return "Browser: \(browser.label)"
        }
        return switch action {
        case chatDelete: L10n.string("Delete Chat")
        case providerDefault: L10n.string("Default model")
        case providerList: L10n.string("List model providers")
        case providerGet: L10n.string("View a model provider")
        case providerValidate: L10n.string("Validate a model provider")
        case providerSave: L10n.string("Save a model provider")
        case providerDelete: L10n.string("Delete a model provider")
        case providerAuthenticate: L10n.string("Sign in to a model provider")
        case providerDeauthenticate: L10n.string("Sign out of a model provider")
        case providerConnect: L10n.string("Connect a model provider")
        case secretList: L10n.string("List secrets")
        case secretAdd: L10n.string("Add a secret")
        case secretDelete: L10n.string("Delete a secret")
        case appInfo: L10n.string("App info")
        case appProfile, appProfiles: L10n.string("Profiles")
        case appNotifications: L10n.string("Notifications")
        case appLanguage: L10n.string("Language")
        case appTheme: L10n.string("Theme")
        case appVoice, appVoiceOptions: L10n.string("Voice")
        case appModel: L10n.string("Model")
        case appDefaultModel: L10n.string("Default model")
        case appActionPolicies: L10n.string("Actions")
        case appRepositories: L10n.string("Repositories")
        case appLogs: L10n.string("Logs")
        case appRenameChat: L10n.string("Rename chat")
        case webSearch: L10n.string("Search the web")
        case webFetch: L10n.string("Fetch a web resource")
        case fsList: L10n.string("List files")
        case fsRead, outputRead: L10n.string("Read a file")
        case fsWrite: L10n.string("Write a file")
        case fsEdit: L10n.string("Edit a file")
        case fsDelete: L10n.string("Delete a file")
        case fsGlob: L10n.string("Find files")
        case fsGrep: L10n.string("Search files")
        case artifactAttach: L10n.string("Attach an artifact")
        case serviceFind: L10n.string("Search services")
        case serviceListAttached: L10n.string("List attached services")
        case serviceInspect: L10n.string("Inspect a service")
        case serviceValidate: L10n.string("Validate a service")
        case serviceCreate: L10n.string("Create a service")
        case serviceUpdate: L10n.string("Update a service")
        case serviceCopy: L10n.string("Copy a service to Local")
        case serviceDelete: L10n.string("Delete a service")
        case repositoryConnect: L10n.string("Add Repository")
        case repositorySync: L10n.string("Sync")
        case repositoryDisconnect: L10n.string("Remove Repository")
        case repositoryPropose: L10n.string("Share Service")
        case repositoryGitStatus, repositoryGitDiff: L10n.string("Check repository changes")
        case repositoryGitLog: L10n.string("Read repository history")
        case repositoryGitShow: L10n.string("Read a saved repository version")
        case repositoryGitCheckout: L10n.string("View a saved repository version")
        case repositoryGitCommit: L10n.string("Save Local repository")
        case repositoryGitRevert: L10n.string("Undo a saved Local version")
        case repositoryGitRestore: L10n.string("Discard Local changes")
        case serviceAttach: L10n.string("Attach a service")
        case serviceSignIn: L10n.string("Service sign-in")
        case serviceSolve: L10n.string("Service verification")
        case servicePayment: L10n.string("Service checkout")
        case serviceDetach: L10n.string("Detach a service")
        case skillShare: L10n.string("Add to Local Repository")
        case skillCreate: L10n.string("Create a skill")
        case skillCopy: L10n.string("Copy a skill")
        case skillDelete: L10n.string("Delete a skill")
        case scheduleCreate: L10n.string("Schedule a skill")
        case scheduleList: L10n.string("List scheduled skills")
        case scheduleDelete: L10n.string("Delete a scheduled skill")
        case scheduleEnable: L10n.string("Change a scheduled skill")
        case scheduleRun: L10n.string("Run a scheduled skill")
        case memoryRead: L10n.string("Read memory")
        case memoryWrite, memoryReplaceText: L10n.string("Update memory")
        case artifactList: L10n.string("List artifacts")
        case artifactImport: L10n.string("Import an artifact")
        case artifactWrite: L10n.string("Write an artifact")
        case artifactReplaceText: L10n.string("Edit an artifact")
        case artifactRename: L10n.string("Rename an artifact")
        case artifactDelete: L10n.string("Delete an artifact")
        case artifactPresent: L10n.string("Present an artifact")
        case widgetShoveler: L10n.string("Display cards")
        case widgetVideo: L10n.string("Display video")
        case userChoose: L10n.string("Ask a question")
        case userFollow: L10n.string("Suggest next steps")
        case userReportProgress: L10n.string("Report progress")
        default: nil
        }
    }

    static func iconKind(for action: String) -> OxActionIconKind? {
        guard builtIn.contains(action) else { return nil }
        if action == appRenameChat || action.hasPrefix("ox.user.") { return .chats }
        if action.hasPrefix("ox.provider.") || action.hasPrefix("ox.app.") || action.hasPrefix("ox.secret.") { return .device }
        if action.hasPrefix("ox.service.") { return .services }
        if action.hasPrefix("ox.artifact.") { return .artifacts }
        if action.hasPrefix("ox.skill.") || action.hasPrefix("ox.schedule.") { return .skills }
        if action.hasPrefix("ox.memory.") { return .memory }
        if action.hasPrefix("ox.web.") { return .web }
        if action.hasPrefix("ox.fs.") || action == outputRead { return .files }
        if action.hasPrefix("ox.widget.") { return .widgets }
        return .code
    }

    static func iconKind(forLabel label: String) -> OxActionIconKind? {
        builtIn.first { self.label(for: $0) == label }.flatMap { iconKind(for: $0) }
    }
}
