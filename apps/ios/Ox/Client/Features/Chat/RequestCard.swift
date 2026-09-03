import SwiftUI
import UIKit

struct PermissionRequest: Identifiable, Equatable {
    let id: UUID
    let prompt: String
    let approve: String
    let alwaysApprove: String?
    let deny: String
    let actionIconKind: OxActionIconKind?

    @MainActor private static var actionIconKindsByTitle: [String: OxActionIconKind] = [:]

    @MainActor init?(id: UUID, prompt: String, options: [String]) {
        guard let approve = options.first,
              let deny = options.last,
              approve != deny else { return nil }
        self.id = id
        self.prompt = prompt
        self.approve = approve
        alwaysApprove = options.count == 3 ? options[1] : nil
        self.deny = deny
        let title = RequestCardCopy(prompt).title
        actionIconKind = title.contains(" - ")
            ? nil
            : Self.actionIconKind(for: title)
    }

    @MainActor init(_ request: ServiceApproval.Request) {
        id = request.id
        prompt = request.prompt
        approve = request.approve
        alwaysApprove = request.alwaysApprove
        deny = request.deny
        let title = RequestCardCopy(request.prompt).title
        actionIconKind = title.contains(" - ") ? nil : Self.actionIconKind(for: title)
    }

    @MainActor private static func actionIconKind(for title: String) -> OxActionIconKind? {
        if let cached = actionIconKindsByTitle[title] { return cached }
        guard let kind = InvocationName.allCases.first(where: { $0.approvalLabel == title })?.actionIconKind else {
            return nil
        }
        actionIconKindsByTitle[title] = kind
        return kind
    }

    private var copy: RequestCardCopy { RequestCardCopy(prompt) }

    var sourceName: String {
        let separator = " - "
        guard let range = copy.title.range(of: separator) else { return "Ox" }
        return String(copy.title[..<range.lowerBound])
    }

    var actionName: String {
        let separator = " - "
        guard let range = copy.title.range(of: separator) else { return "Ox · \(copy.title)" }
        return "\(copy.title[..<range.lowerBound]) · \(copy.title[range.upperBound...])"
    }

    var options: [String] {
        [approve, alwaysApprove, deny].compactMap { $0 }
    }
}

struct AgentChoiceRequest: Identifiable, Equatable {
    let id: UUID
    let prompt: String
    let options: [String]
    let allowsCustomAnswer: Bool

    init(id: UUID, prompt: String, options: [String], allowsCustomAnswer: Bool) {
        self.id = id
        self.prompt = prompt
        self.options = options
        self.allowsCustomAnswer = allowsCustomAnswer
    }
}

struct AgentChoiceRequestCard: View {
    let request: AgentChoiceRequest
    var selection: String? = nil
    var resolution: String? = nil
    let composerButtonSize: CGFloat
    let onCustomFocusChange: (Bool) -> Void
    let onSelect: (String) -> Void

    @Environment(\.appTheme) private var appTheme

    var body: some View {
        let copy = RequestCardCopy(request.prompt)
        RequestCard(title: copy.title, message: copy.message) {
            RequestCardOptions(
                options: request.options,
                selection: selection,
                resolution: resolution,
                composerButtonSize: composerButtonSize,
                onCustomFocusChange: onCustomFocusChange,
                kind: .choice(allowsCustomAnswer: request.allowsCustomAnswer),
                onSelect: onSelect
            )
        }
        .padding(Theme.Spacing.lg)
        .background {
            Color.clear
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
                .id(appTheme)
        }
        .accessibilityElement(children: .contain)
    }
}

struct PermissionRequestCard: View {
    let request: PermissionRequest
    var selection: String? = nil
    var resolution: String? = nil
    let onSelect: (String) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.appTheme) private var appTheme
    @State private var submittedSelection: String?

    private var copy: RequestCardCopy { RequestCardCopy(request.prompt) }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            HStack(spacing: 6) {
                PermissionSourceIcon(sourceName: request.sourceName, actionIconKind: request.actionIconKind)
                    .accessibilityHidden(true)
                Text(verbatim: request.actionName)
                    .font(Theme.Fonts.captionMd)
                    .foregroundStyle(Theme.Colors.onSurfaceMuted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(A11yID.Chat.permissionRequest(request.actionIconKind?.rawValue ?? "source"))

            if let message = copy.message {
                Text(message)
                    .font(Theme.Fonts.bodySm)
                    .foregroundStyle(Theme.Colors.onSurface)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            permissionActions
        }
        .padding(Theme.Spacing.lg)
        .background {
            Color.clear
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
                .id(appTheme)
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var permissionActions: some View {
        if let selection = selection ?? submittedSelection {
            RequestCardOptions(
                options: request.options,
                selection: selection,
                resolution: resolution,
                kind: .permission,
                onSelect: onSelect
            )
                .transition(.scale(scale: 0.97).combined(with: .opacity))
        } else {
            PermissionActionButtons(options: request.options, onSelect: select)
                .transition(.opacity)
        }
    }

    private func select(_ option: String) {
        guard submittedSelection == nil else { return }
        Haptics.impact(.selectionConfirmed)
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.24, extraBounce: 0.04)) {
            submittedSelection = option
        }
        onSelect(option)
    }
}

private struct PermissionSourceIcon: View {
    let sourceName: String
    let actionIconKind: OxActionIconKind?

    @Environment(ServiceManager.self) private var serviceManager

    private var service: Service? {
        serviceManager.services.first {
            $0.title.localizedCaseInsensitiveCompare(sourceName) == .orderedSame
        }
    }

    var body: some View {
        Group {
            if let service {
                ServiceAvatar(service: service, size: 18, shape: .roundedRect(4), monogramSize: 9)
            } else if sourceName == "Ox", let actionIconKind {
                OxActionIcon(actionIconKind, size: 16)
                    .foregroundStyle(Theme.Colors.onSurfaceMuted)
            } else if sourceName == "Ox" {
                Image(.oxIcon)
                    .resizable()
                    .scaledToFill()
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            } else {
                nativeIcon
            }
        }
        .frame(width: 18, height: 18)
    }

    private var nativeIcon: some View {
        Image(systemName: nativeSymbol)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Theme.Colors.onSurface)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.Colors.surfaceSunken, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
    }

    private var nativeSymbol: String {
        switch sourceName {
        case "Calendar": "calendar"
        case "Reminders": "checklist"
        case "Contacts": "person.crop.circle"
        default: "app.fill"
        }
    }
}

struct RequestPillButton: View {
    let title: String
    let isPrimary: Bool
    var isLoading = false
    var loadingLabel = String(localized: "Loading…")
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if isLoading {
                    CellularAutomatonLoader(
                        size: 16,
                        tint: isPrimary ? Theme.Colors.onPrimary.dynamic : Theme.Colors.onSurface.dynamic
                    )
                    .accessibilityLabel(loadingLabel)
                } else {
                    Text(title)
                        .font(Theme.Fonts.labelMd)
                        .foregroundStyle(isPrimary ? Theme.Colors.onPrimary : Theme.Colors.onSurface)
                        .lineLimit(1)
                }
            }
                .padding(.horizontal, Theme.Spacing.lg)
                .frame(minWidth: 72, minHeight: 36)
                .background(
                    isPrimary ? AnyShapeStyle(Theme.Colors.primary) : AnyShapeStyle(Theme.Colors.surfaceSunken),
                    in: Capsule(style: .continuous)
                )
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(RequestButtonStyle())
    }
}

struct RequestCard<Content: View>: View {
    let title: String
    let message: String?
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text(title)
                    .font(Theme.Fonts.title)
                    .foregroundStyle(Theme.Colors.onSurface)
                    .fixedSize(horizontal: false, vertical: true)
                if let message, !message.isEmpty {
                    Text(message)
                        .font(Theme.Fonts.bodySm)
                        .foregroundStyle(Theme.Colors.onSurfaceMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }
}

struct RequestCardOptions: View {
    enum Kind {
        case permission
        case choice(allowsCustomAnswer: Bool)
    }

    let options: [String]
    let selection: String?
    let resolution: String?
    var composerButtonSize: CGFloat = 34
    var onCustomFocusChange: (Bool) -> Void = { _ in }
    let kind: Kind
    let onSelect: (String) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var submittedSelection: String?
    @State private var customAnswer = ""
    @FocusState private var customAnswerFocused: Bool

    private var allowsCustomAnswer: Bool {
        guard case let .choice(allowsCustomAnswer) = kind else { return false }
        return allowsCustomAnswer
    }

    private var usesBinaryLayout: Bool {
        guard case .choice = kind else { return false }
        return Set(options.map { $0.lowercased() }) == ["yes", "no"]
    }

    private var effectiveSelection: String? {
        selection ?? submittedSelection
    }

    var body: some View {
        if let effectiveSelection {
            resolutionLabel(
                resolution ?? effectiveSelection,
                selection: effectiveSelection,
                wasSelected: options.contains(effectiveSelection)
            )
            .transition(.scale(scale: 0.97).combined(with: .opacity))
        } else {
            optionButtons
                .transition(.opacity)
        }
    }

    @ViewBuilder
    private var optionButtons: some View {
        switch kind {
        case .permission:
            permissionOptions
        case .choice:
            if usesBinaryLayout {
                binaryChoiceOptions
            } else {
                choiceOptions
            }
        }
    }

    private var binaryChoiceOptions: some View {
        VStack(spacing: Theme.Spacing.sm) {
            ForEach(options, id: \.self) { option in
                RequestActionButton(
                    title: option,
                    isPrimary: option.lowercased() == "yes",
                    cornerRadius: Theme.Radius.full,
                    action: { select(option) }
                )
                .accessibilityIdentifier(A11yID.Chat.confirm(option))
            }
        }
    }

    private func resolutionLabel(_ text: String, selection: String, wasSelected: Bool) -> some View {
        Label(text, systemImage: wasSelected ? "checkmark.circle.fill" : "stop.circle.fill")
            .font(Theme.Fonts.labelMd)
            .foregroundStyle(wasSelected ? Theme.Colors.primary : Theme.Colors.onSurfaceMuted)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, Theme.Spacing.sm)
            .frame(minHeight: Theme.Size.minimumTouchTarget)
            .background(
                Theme.Colors.surfaceSunken,
                in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
            )
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(A11yID.Chat.confirmReceipt(selection))
    }

    private var choiceOptions: some View {
        VStack(spacing: 0) {
            ForEach(options.indices, id: \.self) { index in
                let option = options[index]
                RequestChoiceButton(
                    number: allowsCustomAnswer ? index + 1 : nil,
                    title: option,
                    action: { select(option) }
                )
                .accessibilityIdentifier(A11yID.Chat.confirm(option))
                if index < options.index(before: options.endIndex) || allowsCustomAnswer {
                    Divider()
                }
            }
            if allowsCustomAnswer {
                customAnswerRow
            }
        }
    }

    private var customAnswerRow: some View {
        HStack(spacing: Theme.Spacing.md) {
            Image("icon.pencil")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 12, height: 18)
                .foregroundStyle(Theme.Colors.onSurfaceMuted)
                .frame(width: 28, height: 28)
                .background(Theme.Colors.surfaceSunken, in: Circle())
                .accessibilityHidden(true)
            TextField("Type your answer…", text: $customAnswer)
                .font(Theme.Fonts.bodyMd)
                .foregroundStyle(Theme.Colors.onSurface)
                .submitLabel(.send)
                .focused($customAnswerFocused)
                .onSubmit(submitCustomAnswer)
                .accessibilityIdentifier(A11yID.Chat.choiceCustomInput)
            if !trimmedCustomAnswer.isEmpty {
                Button(action: submitCustomAnswer) {
                    Image(systemName: "arrow.up")
                        .font(.system(.subheadline, weight: .bold))
                        .foregroundStyle(Theme.Colors.onPrimary)
                        .frame(width: composerButtonSize, height: composerButtonSize)
                        .background(Theme.Colors.primary, in: Circle())
                        .minimumTouchTarget()
                }
                .buttonStyle(.plain)
                .accessibilityLabel(A11yLabel.send)
                .accessibilityIdentifier(A11yID.Chat.choiceCustomSubmit)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 44)
        .onChange(of: customAnswerFocused) { _, focused in
            onCustomFocusChange(focused)
        }
        .onDisappear {
            if customAnswerFocused { onCustomFocusChange(false) }
        }
    }

    private var trimmedCustomAnswer: String {
        customAnswer.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func submitCustomAnswer() {
        let answer = trimmedCustomAnswer
        guard !answer.isEmpty else { return }
        customAnswerFocused = false
        select(answer)
    }

    private var permissionOptions: some View {
        PermissionActionButtons(options: options, onSelect: select)
    }

    private func select(_ option: String) {
        guard effectiveSelection == nil else { return }
        Haptics.impact(.selectionConfirmed)
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.24, extraBounce: 0.04)) {
            submittedSelection = option
        }
        onSelect(option)
    }
}

struct PermissionActionButtons: View {
    let options: [String]
    let onSelect: (String) -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(spacing: Theme.Spacing.sm) {
            if let approve = options.first {
                actionButton(approve, isPrimary: true)
            }
            if options.count == 3 {
                if dynamicTypeSize.isAccessibilitySize {
                    actionButton(options[1], isPrimary: false)
                    actionButton(options[2], isPrimary: false)
                } else {
                    HStack(spacing: Theme.Spacing.sm) {
                        actionButton(options[1], isPrimary: false)
                        actionButton(options[2], isPrimary: false)
                    }
                }
            } else {
                ForEach(Array(options.dropFirst()), id: \.self) { option in
                    actionButton(option, isPrimary: false)
                }
            }
        }
    }

    private func actionButton(_ option: String, isPrimary: Bool) -> some View {
        RequestActionButton(
            title: option,
            isPrimary: isPrimary,
            cornerRadius: Theme.Radius.full,
            action: { onSelect(option) }
        )
        .accessibilityIdentifier(A11yID.Chat.confirm(option))
    }
}

private struct RequestActionButton: View {
    let title: String
    let isPrimary: Bool
    var cornerRadius = Theme.Radius.md
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            label
        }
        .buttonStyle(RequestButtonStyle())
    }

    private var label: some View {
        HStack(spacing: 6) {
            Text(title)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .font(Theme.Fonts.labelMd)
        .foregroundStyle(isPrimary ? Theme.Colors.onPrimary : Theme.Colors.onSurface)
        .frame(maxWidth: .infinity, minHeight: 44)
        .padding(.horizontal, Theme.Spacing.sm)
        .background(
            isPrimary ? AnyShapeStyle(Theme.Colors.primary) : AnyShapeStyle(Theme.Colors.surfaceSunken),
            in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        )
    }
}

private struct RequestChoiceButton: View {
    let number: Int?
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            label
        }
        .buttonStyle(RequestButtonStyle())
    }

    private var label: some View {
        HStack(spacing: Theme.Spacing.md) {
            indicator
            Text(title)
                .font(Theme.Fonts.bodyMd)
                .foregroundStyle(Theme.Colors.onSurface)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 44)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var indicator: some View {
        if let number {
            Text(verbatim: "\(number)")
                .font(Theme.Fonts.labelMd)
                .foregroundStyle(Theme.Colors.onSurfaceMuted)
                .frame(width: 28, height: 28)
                .background(Theme.Colors.surfaceSunken, in: Circle())
                .accessibilityHidden(true)
        } else {
            Image(systemName: "circle")
                .font(Theme.Icons.md)
                .foregroundStyle(Theme.Colors.onSurfaceMuted)
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)
        }
    }
}

struct RequestButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(reduceMotion || !configuration.isPressed ? 1 : 0.98)
            .opacity(configuration.isPressed ? 0.82 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct RequestCardCopy {
    let title: String
    let message: String?

    init(_ prompt: String) {
        let lines = prompt
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        title = lines.first ?? prompt
        let detail = lines.dropFirst().joined(separator: "\n")
        message = detail.isEmpty ? nil : detail
    }
}
