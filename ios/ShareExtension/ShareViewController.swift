import UIKit
import SwiftUI
import UniformTypeIdentifiers
import os

private enum ShareLog {
    static let logger = os.Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "ai.openox.ShareExtension",
        category: "Share"
    )
}

final class ShareViewController: UIViewController {
    private var hostingController: UIHostingController<ShareView>?

    override func viewDidLoad() {
        super.viewDidLoad()
        preferredContentSize = CGSize(width: 420, height: 330)
        let rootView = ShareView(
            inputItems: extensionContext?.inputItems ?? [],
            onCancel: { [weak self] in
                self?.extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
            },
            onComplete: { [weak self] in
                self?.extensionContext?.completeRequest(returningItems: nil)
            }
        )
        let hostingController = UIHostingController(rootView: rootView)
        hostingController.view.backgroundColor = .clear
        addChild(hostingController)
        hostingController.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hostingController.view)
        NSLayoutConstraint.activate([
            hostingController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hostingController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hostingController.view.topAnchor.constraint(equalTo: view.topAnchor),
            hostingController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        hostingController.didMove(toParent: self)
        self.hostingController = hostingController
    }
}

private struct ShareView: View {
    private enum LoadState {
        case loading
        case ready(SharedImportPayload)
        case failed(String)
    }

    let inputItems: [Any]
    let onCancel: () -> Void
    let onComplete: () -> Void
    @State private var loadState = LoadState.loading
    @State private var adding = false

    var body: some View {
        ZStack {
            ShareTheme.background.ignoresSafeArea()
            VStack(alignment: .leading, spacing: ShareTheme.outerInset) {
                Text("Add to Ox")
                    .font(ShareTheme.headline)
                    .foregroundStyle(ShareTheme.onSurface)
                    .frame(maxWidth: .infinity, alignment: .leading)

                content
                Spacer(minLength: ShareTheme.spacingLarge)
                actions
            }
            .padding(ShareTheme.outerInset)
        }
        .preferredColorScheme(ShareTheme.colorScheme)
        .task { await load() }
    }

    @ViewBuilder
    private var content: some View {
        switch loadState {
        case .loading:
            HStack(spacing: ShareTheme.spacingMedium) {
                ProgressView().tint(ShareTheme.primary)
                Text("Reading shared items…")
                    .font(ShareTheme.body)
                    .foregroundStyle(ShareTheme.onSurfaceMuted)
            }
            .shareCard()
        case .ready(let payload):
            VStack(alignment: .leading, spacing: ShareTheme.spacingMedium) {
                Text(payload.preview)
                    .font(ShareTheme.body)
                    .foregroundStyle(ShareTheme.onSurface)
                    .lineLimit(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(payload.status)
                    .font(ShareTheme.caption)
                    .foregroundStyle(ShareTheme.onSurfaceMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .shareCard()
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.circle.fill")
                .font(ShareTheme.body)
                .foregroundStyle(ShareTheme.error)
                .frame(maxWidth: .infinity, alignment: .leading)
                .shareCard()
        }
    }

    private var actions: some View {
        HStack(spacing: ShareTheme.spacingMedium) {
            Button(action: onCancel) {
                Text("Cancel")
                    .font(ShareTheme.label)
                    .foregroundStyle(ShareTheme.onSurface)
                    .padding(.horizontal, ShareTheme.spacingLarge)
                    .frame(height: 44)
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: Capsule())
            .accessibilityIdentifier("share.cancel")

            Spacer(minLength: 0)

            Button(action: add) {
                Group {
                    if adding {
                        ProgressView().tint(ShareTheme.onPrimary)
                    } else {
                        Text("Add")
                    }
                }
                .font(ShareTheme.label)
                .foregroundStyle(ShareTheme.onPrimary)
                .frame(minWidth: 56)
                .padding(.horizontal, ShareTheme.spacingLarge)
                .frame(height: 44)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.tint(ShareTheme.primary).interactive(), in: Capsule())
            .disabled(payload == nil || adding)
            .opacity(payload == nil ? 0.45 : 1)
            .accessibilityIdentifier("share.add")
        }
    }

    private var payload: SharedImportPayload? {
        guard case .ready(let payload) = loadState else { return nil }
        return payload
    }

    private func load() async {
        do {
            loadState = .ready(try await SharedItemReader.read(inputItems))
        } catch {
            ShareLog.logger.error("ShareView.load error=\(error.localizedDescription, privacy: .public)")
            loadState = .failed(error.localizedDescription)
        }
    }

    private func add() {
        guard let payload else { return }
        adding = true
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        do {
            try SharedItemWriter.enqueue(payload)
            onComplete()
        } catch {
            loadState = .failed(error.localizedDescription)
            adding = false
        }
    }
}

private extension View {
    func shareCard() -> some View {
        padding(ShareTheme.spacingLarge)
            .background {
                Color.clear.glassEffect(
                    .regular,
                    in: RoundedRectangle(cornerRadius: ShareTheme.radiusLarge, style: .continuous)
                )
            }
    }
}

private enum ShareTheme {
    private enum Selection: String {
        case creatorPick
        case light
        case dark
    }

    private static var selection: Selection {
        UserDefaults(suiteName: SharedItemWriter.appGroupIdentifier)?
            .string(forKey: "app.theme")
            .flatMap(Selection.init(rawValue:)) ?? .creatorPick
    }

    static let spacingMedium: CGFloat = 12
    static let spacingLarge: CGFloat = 16
    static let outerInset: CGFloat = 24
    static let radiusLarge: CGFloat = 18
    static let headline = Font.system(.title2, design: .rounded).weight(.semibold)
    static let body = Font.body
    static let caption = Font.caption
    static let label = Font.system(.subheadline, design: .rounded).weight(.semibold)
    static var background: Color { color(brand: 0xFFF6E6, light: 0xF5F5F5, dark: 0x0A0A0A) }
    static var onSurface: Color { color(brand: 0x3A2410, light: 0x000000, dark: 0xECECEC) }
    static var onSurfaceMuted: Color { color(brand: 0x7A5A3A, light: 0x8E8E93, dark: 0x9A9A9A) }
    static var primary: Color { color(brand: 0xFFA500, light: 0xFFA500, dark: 0xF5A030) }
    static var onPrimary: Color { Color(uiColor: UIColor(hex: 0xFFFDF7)) }
    static var error: Color { color(brand: 0xB8422E, light: 0xB8422E, dark: 0xE25A45) }
    static var colorScheme: ColorScheme { selection == .dark ? .dark : .light }

    private static func color(brand: UInt32, light: UInt32, dark: UInt32) -> Color {
        let hex = switch selection {
        case .creatorPick: brand
        case .light: light
        case .dark: dark
        }
        return Color(uiColor: UIColor(hex: hex))
    }
}

private extension UIColor {
    convenience init(hex: UInt32) {
        let red = CGFloat((hex >> 16) & 0xFF) / 255
        let green = CGFloat((hex >> 8) & 0xFF) / 255
        let blue = CGFloat(hex & 0xFF) / 255
        self.init(red: red, green: green, blue: blue, alpha: 1)
    }
}

private struct SharedImportPayload {
    let artifacts: [SharedArtifactPayload]

    var preview: String {
        if artifacts.count == 1 { return artifacts[0].preview }
        return artifacts.prefix(4).map(\.fileName).joined(separator: "\n")
    }

    var status: String {
        if artifacts.count == 1 {
            return String(localized: "It’ll appear in Artifacts the next time you open Ox.")
        }
        return String.localizedStringWithFormat(
            String(localized: "%lld items will appear in Artifacts the next time you open Ox."),
            artifacts.count
        )
    }
}

private struct SharedArtifactPayload {
    let fileName: String
    let data: Data
    let preview: String
}

private enum LoadedAttachment {
    case artifact(SharedArtifactPayload)
    case link(SharedArtifactPayload)
    case text(String)
}

private enum SharedItemReader {
    private static let maximumItemCount = 10
    private static let maximumTextBytes = 200 * 1024
    private static let maximumMediaBytes = 32 * 1024 * 1024

    static func read(_ inputItems: [Any]) async throws -> SharedImportPayload {
        var titles: [String] = []
        var textParts: [String] = []
        var artifacts: [SharedArtifactPayload] = []
        let extensionItems = inputItems.compactMap { $0 as? NSExtensionItem }
        let providers = extensionItems.flatMap { $0.attachments ?? [] }
        ShareLog.logger.info("SharedItemReader.read items=\(extensionItems.count) providers=\(providers.count)")
        guard providers.count <= maximumItemCount else { throw SharedItemError.tooManyItems }

        for item in extensionItems {
            let itemTitle = item.attributedTitle?.string
            append(itemTitle, to: &titles)
            var containsLink = false
            for provider in item.attachments ?? [] {
                guard let attachment = try await attachment(from: provider, title: itemTitle) else { continue }
                switch attachment {
                case .artifact(let artifact): artifacts.append(artifact)
                case .link(let artifact):
                    artifacts.append(artifact)
                    containsLink = true
                case .text(let text): append(text, to: &textParts)
                }
            }
            if !containsLink { append(item.attributedContentText?.string, to: &textParts) }
        }

        let text = textParts.joined(separator: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            let data = Data(text.utf8)
            guard data.count <= maximumTextBytes else { throw SharedItemError.tooLarge }
            let title = titles.first ?? firstLineTitle(text) ?? String(localized: "Shared Note")
            artifacts.insert(
                SharedArtifactPayload(
                    fileName: fileName(sanitizedTitle(title), defaultExtension: "md"),
                    data: data,
                    preview: textPreview(text)
                ),
                at: 0
            )
        }

        guard !artifacts.isEmpty else {
            let identifiers = providers.flatMap(\.registeredTypeIdentifiers).joined(separator: ",")
            ShareLog.logger.error("SharedItemReader.unsupported providerTypes=\(identifiers, privacy: .public)")
            throw SharedItemError.unsupported
        }
        ShareLog.logger.info("SharedItemReader.ready artifacts=\(artifacts.count) textParts=\(textParts.count)")
        return SharedImportPayload(artifacts: artifacts)
    }

    private static func attachment(from provider: NSItemProvider, title: String?) async throws -> LoadedAttachment? {
        if provider.hasItemConformingToTypeIdentifier(UTType.pdf.identifier),
           let data = await data(from: provider, identifier: UTType.pdf.identifier) {
            return .artifact(try artifact(
                data: data,
                suggestedName: provider.suggestedName,
                fallbackName: String(localized: "Shared PDF"),
                defaultExtension: "pdf"
            ))
        }

        if let identifier = provider.registeredTypeIdentifiers.first(where: { identifier in
            guard let type = UTType(identifier) else { return false }
            return [UTType.jpeg, .png, .gif, .webP, .heic, .heif].contains { type.conforms(to: $0) }
        }), let data = await data(from: provider, identifier: identifier) {
            let fileExtension = UTType(identifier)?.preferredFilenameExtension ?? "jpg"
            return .artifact(try artifact(
                data: data,
                suggestedName: provider.suggestedName,
                fallbackName: String(localized: "Shared Image"),
                defaultExtension: fileExtension
            ))
        }

        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
           let url = await sharedURL(from: provider) {
            if url.isFileURL {
                if let artifact = try fileArtifact(at: url, from: provider) {
                    return .artifact(artifact)
                }
            } else {
                let urlString = url.absoluteString
                let linkTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
                let name = if let linkTitle, !linkTitle.isEmpty {
                    linkTitle
                } else {
                    url.host() ?? String(localized: "Shared Link")
                }
                return .link(SharedArtifactPayload(
                    fileName: fileName(name, defaultExtension: "md"),
                    data: Data(urlString.utf8),
                    preview: urlString
                ))
            }
        }

        if let identifier = provider.registeredTypeIdentifiers.first(where: { identifier in
            guard let type = UTType(identifier) else { return false }
            return type.conforms(to: .text)
                || type.conforms(to: .sourceCode)
                || type.conforms(to: .json)
                || type.conforms(to: .commaSeparatedText)
        }), let data = await data(from: provider, identifier: identifier) {
            guard data.count <= maximumTextBytes else { throw SharedItemError.tooLarge }
            let type = UTType(identifier)
            if let text = decodedText(data, type: type) {
                if type?.conforms(to: .rtf) == true || type?.conforms(to: .rtfd) == true {
                    return .text(text)
                }
                if let suggestedName = provider.suggestedName,
                   !URL(fileURLWithPath: suggestedName).pathExtension.isEmpty {
                    return .artifact(try artifact(
                        data: data,
                        suggestedName: suggestedName,
                        fallbackName: String(localized: "Shared Text"),
                        defaultExtension: type?.preferredFilenameExtension ?? "txt",
                        preview: textPreview(text)
                    ))
                }
                return .text(text)
            }
        }

        if let text = try await convertedText(from: provider) {
            return .text(text)
        }

        let identifiers = provider.registeredTypeIdentifiers.joined(separator: ",")
        ShareLog.logger.error("SharedItemReader.providerUnreadable providerTypes=\(identifiers, privacy: .public)")
        return nil
    }

    private static func fileArtifact(at url: URL, from provider: NSItemProvider) throws -> SharedArtifactPayload? {
        let type = UTType(filenameExtension: url.pathExtension)
            ?? provider.registeredTypeIdentifiers.compactMap(UTType.init).first(where: supportedFileType)
        guard let type, supportedFileType(type) else { return nil }
        guard let data = try? Data(contentsOf: url) else {
            ShareLog.logger.error("SharedItemReader.fileUnreadable type=\(type.identifier, privacy: .public)")
            return nil
        }

        let isText = type.conforms(to: .text)
            || type.conforms(to: .sourceCode)
            || type.conforms(to: .json)
            || type.conforms(to: .commaSeparatedText)
        if isText {
            guard data.count <= maximumTextBytes else { throw SharedItemError.tooLarge }
            guard let text = decodedText(data, type: type) else { return nil }
            return try artifact(
                data: data,
                suggestedName: provider.suggestedName ?? url.lastPathComponent,
                fallbackName: String(localized: "Shared Text"),
                defaultExtension: type.preferredFilenameExtension ?? "txt",
                preview: textPreview(text)
            )
        }

        return try artifact(
            data: data,
            suggestedName: provider.suggestedName ?? url.lastPathComponent,
            fallbackName: String(localized: type.conforms(to: .pdf) ? "Shared PDF" : "Shared Image"),
            defaultExtension: type.preferredFilenameExtension ?? "bin"
        )
    }

    private static func supportedFileType(_ type: UTType) -> Bool {
        type.conforms(to: .text)
            || type.conforms(to: .sourceCode)
            || type.conforms(to: .json)
            || type.conforms(to: .commaSeparatedText)
            || type.conforms(to: .pdf)
            || [UTType.jpeg, .png, .gif, .webP, .heic, .heif].contains { type.conforms(to: $0) }
    }

    private static func convertedText(from provider: NSItemProvider) async throws -> String? {
        let types: [UTType] = [.utf8PlainText, .plainText, .rtf, .rtfd, .html, .text]
        for type in types where provider.hasItemConformingToTypeIdentifier(type.identifier) {
            if type == .text,
               let text = await itemText(from: provider, identifier: type.identifier, type: type) {
                guard text.utf8.count <= maximumTextBytes else { throw SharedItemError.tooLarge }
                ShareLog.logger.info("SharedItemReader.convertedText type=\(type.identifier, privacy: .public) source=item")
                return text
            }
            if let data = await data(from: provider, identifier: type.identifier),
               let text = decodedText(data, type: type) {
                guard text.utf8.count <= maximumTextBytes else { throw SharedItemError.tooLarge }
                ShareLog.logger.info("SharedItemReader.convertedText type=\(type.identifier, privacy: .public) source=data")
                return text
            }
            if let text = await itemText(from: provider, identifier: type.identifier, type: type) {
                guard text.utf8.count <= maximumTextBytes else { throw SharedItemError.tooLarge }
                ShareLog.logger.info("SharedItemReader.convertedText type=\(type.identifier, privacy: .public) source=item")
                return text
            }
        }
        return nil
    }

    private static func decodedText(_ data: Data, type: UTType?) -> String? {
        if let documentType = documentType(for: type),
           let attributed = try? NSAttributedString(
               data: data,
               options: [.documentType: documentType],
               documentAttributes: nil
           ) {
            return attributed.string
        }
        return String(data: data, encoding: .utf8)
    }

    private static func documentType(for type: UTType?) -> NSAttributedString.DocumentType? {
        if type?.conforms(to: .rtf) == true {
            .rtf
        } else if type?.conforms(to: .rtfd) == true {
            .rtfd
        } else if type?.conforms(to: .html) == true {
            .html
        } else {
            nil
        }
    }

    private static func itemText(from provider: NSItemProvider, identifier: String, type: UTType) async -> String? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: identifier, options: nil) { item, error in
                let text: String?
                if let attributed = item as? NSAttributedString {
                    text = attributed.string
                } else if let string = item as? String {
                    text = string
                } else if let data = item as? Data {
                    text = decodedText(data, type: type)
                } else if let url = item as? URL,
                          let data = try? Data(contentsOf: url) {
                    text = decodedText(data, type: type)
                } else {
                    text = nil
                }
                if let error {
                    ShareLog.logger.debug("SharedItemReader.loadItem type=\(identifier, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                }
                continuation.resume(returning: text)
            }
        }
    }

    private static func artifact(
        data: Data,
        suggestedName: String?,
        fallbackName: String,
        defaultExtension: String,
        preview: String? = nil
    ) throws -> SharedArtifactPayload {
        guard data.count <= maximumMediaBytes else { throw SharedItemError.tooLarge }
        let name = fileName(suggestedName ?? fallbackName, defaultExtension: defaultExtension)
        return SharedArtifactPayload(fileName: name, data: data, preview: preview ?? name)
    }

    private static func data(from provider: NSItemProvider, identifier: String) async -> Data? {
        await withCheckedContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: identifier) { data, error in
                if let error {
                    ShareLog.logger.debug("SharedItemReader.loadData type=\(identifier, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                }
                continuation.resume(returning: data)
            }
        }
    }

    private static func sharedURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { item, _ in
                let value: URL?
                if let url = item as? URL {
                    value = url
                } else if let url = item as? NSURL {
                    value = url as URL
                } else if let string = item as? String {
                    value = URL(string: string)
                } else if let data = item as? Data {
                    value = String(data: data, encoding: .utf8).flatMap(URL.init(string:))
                } else {
                    value = nil
                }
                continuation.resume(returning: value)
            }
        }
    }

    private static func append(_ candidate: String?, to values: inout [String]) {
        guard let value = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty,
              !values.contains(value) else { return }
        values.append(value)
    }

    private static func firstLineTitle(_ text: String) -> String? {
        text.split(whereSeparator: \Character.isNewline).first.map(String.init)
    }

    private static func textPreview(_ text: String) -> String {
        text.split(whereSeparator: \Character.isNewline).prefix(4).joined(separator: "\n")
    }

    private static func sanitizedTitle(_ title: String) -> String {
        var value = title.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.first == "#" { value.removeFirst() }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let titleExtension = URL(fileURLWithPath: value).pathExtension.lowercased()
        if ["md", "markdown", "txt", "rtf"].contains(titleExtension) {
            value = URL(fileURLWithPath: value).deletingPathExtension().lastPathComponent
        }
        return value
    }

    private static func fileName(_ candidate: String, defaultExtension: String) -> String {
        let source = URL(fileURLWithPath: candidate).lastPathComponent
        let sourceURL = URL(fileURLWithPath: source)
        let sourceExtension = sourceURL.pathExtension
        var stem = sourceExtension.isEmpty ? source : sourceURL.deletingPathExtension().lastPathComponent
        stem = stem.trimmingCharacters(in: .whitespacesAndNewlines)
        while stem.last == "." { stem.removeLast() }
        stem = stem.components(
            separatedBy: CharacterSet(charactersIn: "/:").union(.controlCharacters)
        ).joined(separator: "-")
        if stem.count > 80 { stem = String(stem.prefix(80)) }
        if stem.isEmpty { stem = String(localized: "Shared Item") }
        return "\(stem).\(sourceExtension.isEmpty ? defaultExtension : sourceExtension)"
    }
}

private enum SharedItemWriter {
    static let appGroupIdentifier = Bundle.main.object(forInfoDictionaryKey: "OXAppGroupIdentifier") as? String ?? "group.ai.openox.local"

    static func enqueue(_ payload: SharedImportPayload) throws {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else { throw SharedItemError.storageUnavailable }
        let root = container.appendingPathComponent("ShareImports", isDirectory: true)
        let stagingRoot = root.appendingPathComponent("Staging", isDirectory: true)
        let pendingRoot = root.appendingPathComponent("Pending", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: pendingRoot, withIntermediateDirectories: true)

        for artifact in payload.artifacts {
            let identifier = UUID().uuidString
            let staging = stagingRoot.appendingPathComponent(identifier, isDirectory: true)
            let pending = pendingRoot.appendingPathComponent(identifier, isDirectory: true)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            do {
                let file = staging.appendingPathComponent(artifact.fileName, isDirectory: false)
                try artifact.data.write(to: file, options: [.atomic, .completeFileProtectionUnlessOpen])
                try FileManager.default.moveItem(at: staging, to: pending)
            } catch {
                try? FileManager.default.removeItem(at: staging)
                throw error
            }
        }
    }
}

private enum SharedItemError: LocalizedError {
    case unsupported
    case tooManyItems
    case tooLarge
    case storageUnavailable

    var errorDescription: String? {
        switch self {
        case .unsupported: String(localized: "Ox can’t import this item yet.")
        case .tooManyItems: String(localized: "You can add up to 10 items at a time.")
        case .tooLarge: String(localized: "This item is too large to import.")
        case .storageUnavailable: String(localized: "Ox’s shared storage isn’t available.")
        }
    }
}
