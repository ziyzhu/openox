import SwiftUI
import UIKit

struct DiffCodeBlockBody: View {
    let code: String
    let accessibilityIdentifier: String
    var fadeKey: Int?
    var isStreaming = false
    @State private var width: CGFloat = 0

    var body: some View {
        let document = DiffDocument(code)
        VStack(alignment: .leading, spacing: 0) {
            if document.files.isEmpty {
                DiffHunkBody(lines: document.codeLines, fadeKey: fadeKey, minWidth: max(0, width - 32))
            } else {
                ForEach(document.files) { file in
                    if file.id != document.files.first?.id {
                        Divider().padding(.horizontal, Theme.Spacing.lg)
                    }
                    DiffFileSection(file: file,
                                    accessibilityIdentifier: "\(accessibilityIdentifier).file.\(file.id)",
                                    fadeKey: fadeKey, isStreaming: isStreaming, width: width)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }
}

private struct DiffFileSection: View {
    let file: DiffDocument.File
    let accessibilityIdentifier: String
    let fadeKey: Int?
    let isStreaming: Bool
    let width: CGFloat
    @State private var expanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Button {
                withAnimation(.spring(duration: 0.22, bounce: 0)) { expanded.toggle() }
                Log.ui.info("Diff.fileDisclosure file=\(file.id) expanded=\(expanded)")
            } label: {
                HStack(alignment: .center, spacing: Theme.Spacing.sm) {
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .font(.system(size: 11, weight: .semibold))
                    VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                        Text(verbatim: file.path ?? L10n.string("File"))
                            .font(Theme.Fonts.captionMd)
                            .lineLimit(2)
                            .truncationMode(.middle)
                        if file.change == .renamed, let oldPath = file.oldPath {
                            Text(verbatim: oldPath)
                                .font(Theme.Fonts.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    Spacer(minLength: Theme.Spacing.sm)
                    if file.change != .modified {
                        changeLabel.font(Theme.Fonts.caption).foregroundStyle(.secondary)
                    }
                    if !isStreaming, file.additions + file.deletions > 0 {
                        DiffChangeCounts(additions: file.additions, deletions: file.deletions)
                    }
                }
                .foregroundStyle(Theme.Colors.onSurface)
                .frame(maxWidth: .infinity, minHeight: Theme.Size.minimumTouchTarget, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, Theme.Spacing.lg)
            .accessibilityIdentifier(accessibilityIdentifier)
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            .accessibilityHint(expanded ? "Collapse file" : "Expand file")
            if expanded {
                if file.change == .binary {
                    Text("Binary file changed")
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, Theme.Spacing.lg)
                } else if file.hunks.allSatisfy({ $0.lines.isEmpty }) {
                    Text(isStreaming ? "Receiving changes…" : "No text changes")
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, Theme.Spacing.lg)
                } else {
                    ForEach(file.hunks) { hunk in
                        if hunk.id != file.hunks.first?.id {
                            Divider().padding(.horizontal, Theme.Spacing.lg)
                        }
                        if !hunk.lines.isEmpty {
                            DiffHunkBody(lines: hunk.lines, fadeKey: fadeKey, minWidth: max(0, width - 32))
                        }
                    }
                }
            }
        }
        .padding(.bottom, expanded ? Theme.Spacing.md : 0)
    }

    private var changeLabel: Text {
        switch file.change {
        case .modified: Text("Modified")
        case .added: Text("Added")
        case .deleted: Text("Deleted")
        case .renamed: Text("Renamed")
        case .binary: Text("Binary")
        }
    }
}

struct DiffChangeCounts: View {
    let additions: Int
    let deletions: Int

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            if additions > 0 {
                Text("+\(additions)").foregroundStyle(DiffColors.addition.dynamic)
            }
            if deletions > 0 {
                Text("−\(deletions)").foregroundStyle(DiffColors.deletion.dynamic)
            }
        }
        .font(Theme.Fonts.caption.monospacedDigit())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Added \(additions), removed \(deletions)")
    }
}

private struct DiffHunkBody: View {
    let lines: [DiffDocument.CodeLine]
    let fadeKey: Int?
    let minWidth: CGFloat

    private var font: UIFont {
        .monospacedSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .footnote).pointSize, weight: .regular)
    }

    private var attributed: NSAttributedString {
        let value = NSMutableAttributedString()
        for (index, line) in lines.enumerated() {
            value.append(NSAttributedString(string: line.text + (index == lines.count - 1 ? "" : "\n"), attributes: [
                .font: font,
                .foregroundColor: DiffColors.foreground(line.kind),
            ]))
        }
        return value
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: Theme.Spacing.md) {
                if lines.contains(where: { $0.oldNumber != nil || $0.newNumber != nil }) {
                    let digits = String(lines.compactMap { max($0.oldNumber ?? 0, $0.newNumber ?? 0) }.max() ?? 0).count
                    let columnWidth = ceil(("0" as NSString).size(withAttributes: [.font: font]).width) * CGFloat(digits)
                    Color.clear
                        .frame(width: columnWidth * 2 + Theme.Spacing.sm)
                        .overlay {
                            GeometryReader { geometry in
                                VStack(spacing: 0) {
                                    ForEach(lines.indices, id: \.self) { index in
                                        HStack(spacing: Theme.Spacing.sm) {
                                            Text(lines[index].oldNumber.map(String.init) ?? "")
                                                .frame(width: columnWidth, alignment: .trailing)
                                            Text(lines[index].newNumber.map(String.init) ?? "")
                                                .frame(width: columnWidth, alignment: .trailing)
                                        }
                                        .frame(height: geometry.size.height / CGFloat(lines.count))
                                    }
                                }
                                .font(Font(font))
                                .foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityHidden(true)
                        .allowsHitTesting(false)
                }
                if let fadeKey {
                    SelectableText(streamingAttributed: attributed, resetKey: fadeKey)
                        .accessibilityLabel(lines.map(\.text).joined(separator: "\n"))
                } else {
                    SelectableText(attributed)
                        .accessibilityLabel(lines.map(\.text).joined(separator: "\n"))
                }
            }
            .fixedSize(horizontal: true, vertical: true)
            .frame(minWidth: minWidth, minHeight: font.lineHeight * CGFloat(lines.count), alignment: .leading)
            .background {
                GeometryReader { geometry in
                    VStack(spacing: 0) {
                        ForEach(lines.indices, id: \.self) { index in
                            DiffColors.background(lines[index].kind)
                                .frame(height: geometry.size.height / CGFloat(max(1, lines.count)))
                        }
                    }
                }
                .allowsHitTesting(false)
            }
            .padding(.horizontal, Theme.Spacing.lg)
        }
        .excludesCompactPageSwitch()
        .defaultScrollAnchor(nil, for: .sizeChanges)
    }
}

enum DiffColors {
    static let addition = DynamicColor(light: 0x246B35, dark: 0x8ED99C)
    static let deletion = DynamicColor(light: 0xB52D40, dark: 0xFFA2AD)
    static let metadata = DynamicColor(light: 0x5D6C79, dark: 0x9BAAB8)

    static func foreground(_ kind: DiffDocument.Kind) -> UIColor {
        switch kind {
        case .addition: addition.uiColor
        case .deletion: deletion.uiColor
        case .metadata, .hunk: metadata.uiColor
        case .context: .label
        }
    }

    static func background(_ kind: DiffDocument.Kind) -> Color {
        switch kind {
        case .addition: addition.dynamic.opacity(0.12)
        case .deletion: deletion.dynamic.opacity(0.12)
        case .hunk: metadata.dynamic.opacity(0.08)
        case .context, .metadata: .clear
        }
    }
}
