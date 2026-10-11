extension Actions {
    static func iconKind(for action: String) -> OxActionIconKind? {
        guard builtIn.contains(action) else { return nil }
        if action == appRenameConversation || action.hasPrefix("ox.user.") { return .conversations }
        if action.hasPrefix("ox.provider.") || action.hasPrefix("ox.app.") || action.hasPrefix("ox.secret.") { return .device }
        if action.hasPrefix("ox.service.") { return .services }
        if action.hasPrefix("ox.vision.") { return .files }
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
