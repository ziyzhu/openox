import SwiftUI

enum LibraryDestination {
    case services
    case artifacts
    case skills

    var title: LocalizedStringKey {
        switch self {
        case .services: "Services"
        case .artifacts: "Artifacts"
        case .skills: "Skills"
        }
    }
}

enum OxActionIconKind: String, Equatable {
    case services
    case artifacts
    case skills
    case memory
    case chats
    case web
    case files
    case help
    case location
    case notifications
    case calendar
    case reminders
    case messages
    case contacts
    case health
    case device
    case code
    case widgets

    init(actionName: String) {
        if let invocation = InvocationName(rawValue: actionName) {
            self = invocation.actionIconKind
            return
        }
        if actionName.hasPrefix("ox.service.invoke(ios:") {
            let parts = actionName.dropFirst("ox.service.invoke(ios:".count).split(separator: ":", maxSplits: 1)
            self = switch parts.first {
            case "location": .location
            case "notifications": .notifications
            case "calendar": .calendar
            case "reminders": .reminders
            case "messages": .messages
            case "contacts": .contacts
            case "health": .health
            case "files": .files
            default: .device
            }
            return
        }
        let parts = actionName.split(separator: ".")
        let namespace = parts.count >= 2 && parts[0] == "ox" ? String(parts[1]) : ""
        self = switch namespace {
        case "app": .device
        case "service": .services
        case "artifact": .artifacts
        case "skill": .skills
        case "memory": .memory
        case "chat": .chats
        case "web": .web
        case "fs": .files
        case "help": .help
        case "native": .device
        case "widget": .widgets
        default: .code
        }
    }

    var libraryDestination: LibraryDestination? {
        switch self {
        case .services: .services
        case .artifacts: .artifacts
        case .skills: .skills
        default: nil
        }
    }

    var systemImage: String {
        switch self {
        case .services: "square.grid.2x2"
        case .artifacts: "square.on.square"
        case .skills: "command"
        case .memory: "brain"
        case .chats: "bubble.left.and.bubble.right"
        case .web: "globe"
        case .files: "folder"
        case .help: "doc.text.magnifyingglass"
        case .location: "location"
        case .notifications: "bell"
        case .calendar: "calendar"
        case .reminders: "checklist"
        case .messages: "message"
        case .contacts: "person.crop.circle"
        case .health: "heart.text.square"
        case .device: "iphone"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .widgets: "rectangle.stack"
        }
    }
}

struct OxActionIcon: View {
    let kind: OxActionIconKind
    private let baseSize: CGFloat

    @ScaledMetric(relativeTo: .body) private var scaledSize: CGFloat = 22

    init(_ kind: OxActionIconKind, size: CGFloat = 22) {
        self.kind = kind
        baseSize = size
        _scaledSize = ScaledMetric(wrappedValue: size, relativeTo: .body)
    }

    @ViewBuilder
    var body: some View {
        if let destination = kind.libraryDestination {
            LibraryDestinationIcon(destination, size: baseSize)
        } else {
            Image(systemName: kind.systemImage)
                .font(.system(size: scaledSize * 0.82, weight: .semibold))
                .frame(width: scaledSize, height: scaledSize)
                .accessibilityHidden(true)
        }
    }
}

struct LibraryDestinationIcon: View {
    let destination: LibraryDestination

    @ScaledMetric(relativeTo: .body) private var size: CGFloat = 22

    init(_ destination: LibraryDestination, size: CGFloat = 22) {
        self.destination = destination
        _size = ScaledMetric(wrappedValue: size, relativeTo: .body)
    }

    var body: some View {
        Canvas { context, canvasSize in
            let side = min(canvasSize.width, canvasSize.height)
            let scale = side / 22
            context.scaleBy(x: scale, y: scale)
            let stroke = StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)

            switch destination {
            case .services:
                for origin in [
                    CGPoint(x: 2, y: 2),
                    CGPoint(x: 13, y: 2),
                    CGPoint(x: 2, y: 13),
                    CGPoint(x: 13, y: 13),
                ] {
                    let tile = Path(roundedRect: CGRect(origin: origin, size: CGSize(width: 7, height: 7)), cornerRadius: 2)
                    context.stroke(tile, with: .foreground, style: stroke)
                }
            case .artifacts:
                let back = Path { path in
                    path.move(to: CGPoint(x: 9, y: 2))
                    path.addLine(to: CGPoint(x: 17, y: 2))
                    path.addCurve(
                        to: CGPoint(x: 20, y: 5),
                        control1: CGPoint(x: 18.7, y: 2),
                        control2: CGPoint(x: 20, y: 3.3)
                    )
                    path.addLine(to: CGPoint(x: 20, y: 13))
                    path.addCurve(
                        to: CGPoint(x: 17, y: 16),
                        control1: CGPoint(x: 20, y: 14.7),
                        control2: CGPoint(x: 18.7, y: 16)
                    )
                }
                let front = Path(roundedRect: CGRect(x: 2, y: 6, width: 14, height: 14), cornerRadius: 3)
                context.stroke(back, with: .foreground, style: stroke)
                context.stroke(front, with: .foreground, style: stroke)
            case .skills:
                let shortcut = Path(roundedRect: CGRect(x: 2, y: 3, width: 18, height: 16), cornerRadius: 3)
                let slash = Path { path in
                    path.move(to: CGPoint(x: 13.5, y: 7))
                    path.addLine(to: CGPoint(x: 8.5, y: 15))
                }
                context.stroke(shortcut, with: .foreground, style: stroke)
                context.stroke(slash, with: .foreground, style: stroke)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct LibraryEmptyNote: View {
    let destination: LibraryDestination
    let title: LocalizedStringKey
    let detail: LocalizedStringKey

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            LibraryDestinationIcon(destination, size: 32)
                .foregroundStyle(Theme.Colors.onSurfaceMuted)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(Theme.Fonts.bodyMd)
                    .foregroundStyle(Theme.Colors.onSurface)
                Text(detail)
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.Colors.onSurfaceMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .settingsSurface()
    }
}
