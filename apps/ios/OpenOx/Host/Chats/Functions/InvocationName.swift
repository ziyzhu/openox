import Foundation

enum InvocationName: String, CaseIterable {
    case appInspect = "ox.app.inspect"
    case appRenameChat = "ox.app.renameChat"
    case webSearch = "ox.web.search"
    case webFetch = "ox.web.fetch"
    case fsList = "ox.fs.list"
    case fsRead = "ox.fs.read"
    case fsWrite = "ox.fs.write"
    case fsEdit = "ox.fs.edit"
    case fsDelete = "ox.fs.delete"
    case fsGlob = "ox.fs.glob"
    case fsGrep = "ox.fs.grep"
    case artifactAttach = "ox.artifact.attach"
    case serviceFind = "ox.service.find"
    case serviceListAttached = "ox.service.listAttached"
    case serviceInspect = "ox.service.inspect"
    case serviceCreate = "ox.service.create"
    case serviceCopy = "ox.service.copy"
    case serviceDelete = "ox.service.delete"
    case serviceGitStatus = "ox.service.git.status"
    case serviceGitLog = "ox.service.git.log"
    case serviceGitShow = "ox.service.git.show"
    case serviceGitDiff = "ox.service.git.diff"
    case serviceGitCheckout = "ox.service.git.checkout"
    case serviceGitCommit = "ox.service.git.commit"
    case serviceGitRevert = "ox.service.git.revert"
    case serviceGitRestore = "ox.service.git.restore"
    case serviceAttach = "ox.service.attach"
    case serviceSignIn = "ox.service.signIn"
    case serviceSolve = "ox.service.solve"
    case servicePayment = "ox.service.pay"
    case serviceDetach = "ox.service.detach"
    case skillCreate = "ox.skill.create"
    case skillCopy = "ox.skill.copy"
    case skillDelete = "ox.skill.delete"
    case memoryRead = "ox.memory.read"
    case memoryWrite = "ox.memory.write"
    case memoryReplaceText = "ox.memory.replaceText"
    case artifactList = "ox.artifact.list"
    case artifactImport = "ox.artifact.import"
    case artifactWrite = "ox.artifact.write"
    case artifactReplaceText = "ox.artifact.replaceText"
    case artifactRename = "ox.artifact.rename"
    case artifactDelete = "ox.artifact.delete"
    case artifactPresent = "ox.artifact.present"
    case widgetShoveler = "ox.widget.shoveler"
    case widgetVideo = "ox.widget.video"
    case userChoose = "ox.user.choose"
    case userReportProgress = "ox.user.reportProgress"

    var approvalLabel: String {
        switch self {
        case .appInspect: L10n.string("Settings")
        case .appRenameChat: L10n.string("Rename chat")
        case .webSearch: L10n.string("Search the web")
        case .webFetch: L10n.string("Fetch a web resource")
        case .fsList: L10n.string("List files")
        case .fsRead: L10n.string("Read a file")
        case .fsWrite: L10n.string("Write a file")
        case .fsEdit: L10n.string("Edit a file")
        case .fsDelete: L10n.string("Delete a file")
        case .fsGlob: L10n.string("Find files")
        case .fsGrep: L10n.string("Search files")
        case .artifactAttach: L10n.string("Attach an artifact")
        case .serviceFind: L10n.string("Search services")
        case .serviceListAttached: L10n.string("List attached services")
        case .serviceInspect: L10n.string("Inspect a service")
        case .serviceCreate: L10n.string("Create a service")
        case .serviceCopy: L10n.string("Copy a service to Local")
        case .serviceDelete: L10n.string("Delete a Local service")
        case .serviceGitStatus: L10n.string("Check service changes")
        case .serviceGitLog: L10n.string("Read service history")
        case .serviceGitShow: L10n.string("Read a service commit")
        case .serviceGitDiff: L10n.string("Check service changes")
        case .serviceGitCheckout: L10n.string("Visit a service commit")
        case .serviceGitCommit: L10n.string("Save Local services")
        case .serviceGitRevert: L10n.string("Revert a Local commit")
        case .serviceGitRestore: L10n.string("Discard Local changes")
        case .serviceAttach: L10n.string("Attach a service")
        case .serviceSignIn: L10n.string("Service sign-in")
        case .serviceSolve: L10n.string("Service verification")
        case .servicePayment: L10n.string("Service checkout")
        case .serviceDetach: L10n.string("Detach a service")
        case .skillCreate: L10n.string("Create a skill")
        case .skillCopy: L10n.string("Copy a skill")
        case .skillDelete: L10n.string("Delete a skill")
        case .memoryRead: L10n.string("Read memory")
        case .memoryWrite, .memoryReplaceText: L10n.string("Update memory")
        case .artifactList: L10n.string("List artifacts")
        case .artifactImport: L10n.string("Import an artifact")
        case .artifactWrite: L10n.string("Write an artifact")
        case .artifactReplaceText: L10n.string("Edit an artifact")
        case .artifactRename: L10n.string("Rename an artifact")
        case .artifactDelete: L10n.string("Delete an artifact")
        case .artifactPresent: L10n.string("Present an artifact")
        case .widgetShoveler: L10n.string("Display cards")
        case .widgetVideo: L10n.string("Display video")
        case .userChoose: L10n.string("Ask a question")
        case .userReportProgress: L10n.string("Report progress")
        }
    }

    var actionIconKind: OxActionIconKind {
        switch self {
        case .appInspect: .device
        case .appRenameChat: .chats
        case .webSearch, .webFetch: .web
        case .fsList, .fsRead, .fsWrite, .fsEdit, .fsDelete, .fsGlob, .fsGrep: .files
        case .artifactAttach, .artifactList, .artifactImport, .artifactWrite,
             .artifactReplaceText, .artifactRename, .artifactDelete, .artifactPresent: .artifacts
        case .serviceFind, .serviceListAttached, .serviceInspect, .serviceCreate, .serviceCopy, .serviceDelete,
             .serviceGitStatus, .serviceGitLog, .serviceGitShow, .serviceGitDiff, .serviceGitCheckout, .serviceGitCommit,
             .serviceGitRevert, .serviceGitRestore,
             .serviceAttach, .serviceSignIn, .serviceSolve, .servicePayment, .serviceDetach: .services
        case .skillCreate, .skillCopy, .skillDelete: .skills
        case .memoryRead, .memoryWrite, .memoryReplaceText: .memory
        case .widgetShoveler, .widgetVideo: .widgets
        case .userChoose, .userReportProgress: .chats
        }
    }
}
