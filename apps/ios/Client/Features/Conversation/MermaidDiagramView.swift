import SwiftUI
@preconcurrency import JavaScriptCore

struct MermaidDiagramView<Fallback: View>: View {
    let source: String
    let maxWidth: CGFloat
    let accessibilityIdentifier: String
    @ViewBuilder let fallback: () -> Fallback

    @Environment(\.colorScheme) private var colorScheme
    @State private var image: UIImage?
    @State private var zoomed = false

    private struct Request: Equatable {
        let source: String
        let width: Int
        let colorScheme: ColorScheme
    }

    var body: some View {
        content
            .task(id: Request(source: source, width: Int(maxWidth), colorScheme: colorScheme)) {
                image = await MermaidDiagrams.image(source, maxWidth: maxWidth, colorScheme: colorScheme)
            }
            .fullScreenCover(isPresented: $zoomed) {
                if let image {
                    FileScreen(onDismiss: { zoomed = false }, dismissIdentifier: A11yID.ConversationControls.Message.diagramClose) { _ in
                        ZoomableImageView(image: image)
                    } actions: {
                        MermaidSourceCopyButton(source: source)
                    }
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        if let image {
            Button { zoomed = true } label: {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: image.size.width)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open diagram")
            .accessibilityHint("Pinch or double-tap to zoom")
            .accessibilityIdentifier("\(accessibilityIdentifier).diagram")
        } else {
            fallback()
        }
    }
}

private struct MermaidSourceCopyButton: View {
    let source: String

    @ScaledMetric(relativeTo: .title3) private var size: CGFloat = 44
    @State private var feedback = CopyFeedback()

    var body: some View {
        Button {
            feedback.copy(source, logMessage: "MermaidDiagram.copySource chars=\(source.count)")
        } label: {
            Image(systemName: feedback.didCopy ? "checkmark" : "doc.on.doc")
                .font(.system(.title3, weight: .semibold))
                .foregroundStyle(Theme.Colors.onSurface)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: size, height: size)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Circle())
        .disabled(feedback.didCopy)
        .accessibilityLabel(A11yLabel.copyCode)
        .accessibilityIdentifier(A11yID.ConversationControls.Message.diagramCopy)
    }
}

private enum MermaidDiagrams {
    private static let cache = NSCache<NSString, UIImage>()

    static func image(_ source: String, maxWidth: CGFloat, colorScheme: ColorScheme) async -> UIImage? {
        guard maxWidth > 0 else { return nil }
        let key = "\(colorScheme)|\(Int(maxWidth))|\(source)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        do {
            let diagram = try await MermaidRenderer.shared.render(source, maxWidth: maxWidth)
            let image = try await WebSnapshot.image(svg: diagram.svg, width: diagram.width, style: style(for: colorScheme))
            cache.setObject(image, forKey: key)
            Log.ui.info("MermaidDiagram.render ready type=\(diagram.type) width=\(Int(diagram.width)) chars=\(source.count)")
            return image
        } catch is CancellationError {
            return nil
        } catch {
            Log.ui.error("MermaidDiagram.render failed chars=\(source.count) error=\(LogPrivacy.text(error.localizedDescription))")
            return nil
        }
    }

    private static func style(for colorScheme: ColorScheme) -> String {
        func hex(_ color: DynamicColor) -> String { String(format: "#%06X", color.hex(for: colorScheme)) }
        let background = hex(Theme.Colors.conversationSurface)
        return "html{background:\(background)}.pele{--pele-bg:\(background);--pele-fg:\(hex(Theme.Colors.onSurface));"
            + "--pele-muted:\(hex(Theme.Colors.onSurfaceMuted));--pele-line:\(hex(Theme.Colors.conversationSecondary));"
            + "--pele-surface:\(hex(Theme.Colors.surface));--pele-surface-alt:\(hex(Theme.Colors.surfaceSunken));"
            + "--pele-border:\(hex(Theme.Colors.onSurfaceMuted));--pele-accent:\(hex(Theme.Colors.primary))}"
    }
}

nonisolated final class MermaidRenderer: @unchecked Sendable {
    static let shared = MermaidRenderer()

    struct Diagram {
        let svg: Data
        let width: CGFloat
        let type: String
    }

    enum RenderError: LocalizedError {
        case missingBundle
        case rejected(String)

        var errorDescription: String? {
            switch self {
            case .missingBundle: "Missing Pele.bundle/pele.js"
            case .rejected(let reason): "Pele rejected the diagram: \(reason)"
            }
        }
    }

    private let queue = DispatchQueue(label: "ox.mermaid.javascript")
    private var context: JSContext?

    func render(_ source: String, maxWidth: CGFloat) async throws -> Diagram {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try self.renderOnQueue(source, maxWidth: maxWidth) })
            }
        }
    }

    private func renderOnQueue(_ source: String, maxWidth: CGFloat) throws -> Diagram {
        let context = try acquireContext()
        context.exception = nil
        let options: [String: Any] = ["maxWidth": Double(maxWidth), "links": false, "images": false]
        let result = context.objectForKeyedSubscript("pele")?.invokeMethod("render", withArguments: [source, options])
        if let exception = context.exception {
            let code = exception.objectForKeyedSubscript("code")?.toString() ?? "unknown"
            let line = exception.objectForKeyedSubscript("line")?.toString() ?? "unknown"
            throw RenderError.rejected("code=\(code) line=\(line)")
        }
        guard let result, let svg = result.objectForKeyedSubscript("svg")?.toString(),
              let width = result.objectForKeyedSubscript("width")?.toDouble(), width > 0 else {
            throw RenderError.rejected("invalid result")
        }
        return Diagram(svg: Data(svg.utf8), width: width, type: result.objectForKeyedSubscript("type")?.toString() ?? "unknown")
    }

    private func acquireContext() throws -> JSContext {
        if let context { return context }
        guard let url = Bundle.main.url(forResource: "pele", withExtension: "js", subdirectory: "Pele.bundle") else {
            throw RenderError.missingBundle
        }
        guard let vm = JSVirtualMachine(), let context = JSContext(virtualMachine: vm) else { throw RenderError.rejected("context unavailable") }
        context.evaluateScript(try String(contentsOf: url, encoding: .utf8), withSourceURL: url)
        if let exception = context.exception { throw RenderError.rejected("load \(exception.toString() ?? "unknown")") }
        self.context = context
        Log.ui.info("MermaidRenderer opened bundle=pele.js")
        return context
    }
}
