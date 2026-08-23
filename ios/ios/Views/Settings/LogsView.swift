import SwiftUI

struct LogsView: View {
    @State private var entries: [LogEntry] = []
    @State private var logFileURL: URL?
    @State private var copyFeedback = CopyFeedback()

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                if entries.isEmpty {
                    Text("No logs yet")
                        .font(Theme.Fonts.bodySm)
                        .foregroundStyle(Theme.Colors.onSurfaceMuted)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, Theme.Spacing.xl)
                } else {
                    ForEach(entries.reversed()) { entry in
                        row(entry)
                    }
                }
            }
            .padding(Theme.Spacing.lg)
        }
        .scrollIndicators(.hidden)
        .background(Theme.Colors.background)
        .navigationTitle("Logs")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { reload() } label: {
                        Label("Reload", systemImage: "arrow.clockwise")
                    }
                    .accessibilityIdentifier(A11yID.Logs.reload)

                    Button { copy() } label: {
                        Label(
                            copyFeedback.didCopy ? "Copied" : "Copy",
                            systemImage: copyFeedback.didCopy ? "checkmark" : "doc.on.doc"
                        )
                    }
                    .disabled(entries.isEmpty)
                    .accessibilityIdentifier(A11yID.Logs.copy)

                    if let logFileURL {
                        ShareLink("Export", item: logFileURL)
                            .accessibilityIdentifier(A11yID.Logs.export)
                    }

                    Button(role: .destructive) { clear() } label: {
                        Label("Clear", systemImage: "trash")
                    }
                    .disabled(entries.isEmpty)
                    .accessibilityIdentifier(A11yID.Logs.clear)
                } label: {
                    Image(systemName: "ellipsis")
                }
            }
        }
        .onAppear { reload() }
    }

    private func row(_ entry: LogEntry) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: Theme.Spacing.xs) {
                Text(entry.level.name.uppercased())
                    .font(Theme.Fonts.captionSm)
                    .foregroundStyle(levelColor(entry.level))
                Text(verbatim: entry.category)
                    .font(Theme.Fonts.captionSm)
                    .foregroundStyle(Theme.Colors.onSurfaceMuted)
                Text(verbatim: "(\(entry.thread))")
                    .font(Theme.Fonts.captionSm)
                    .foregroundStyle(Theme.Colors.onSurfaceMuted)
                Spacer(minLength: 0)
                Text(verbatim: LogStore.timeFormatter.string(from: entry.date))
                    .font(Theme.Fonts.monoSm)
                    .foregroundStyle(Theme.Colors.onSurfaceMuted)
            }
            Text(verbatim: entry.message)
                .font(Theme.Fonts.monoSm)
                .foregroundStyle(Theme.Colors.onSurface)
                .textSelection(.enabled)
            Text(verbatim: entry.location)
                .font(Theme.Fonts.monoSm)
                .foregroundStyle(Theme.Colors.onSurfaceMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Spacing.sm)
        .background(Theme.Colors.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
    }

    private func levelColor(_ level: Logger.Level) -> DynamicColor {
        switch level {
        case .warning:       return Theme.Colors.primary
        case .error:         return Theme.Colors.error
        default:             return Theme.Colors.primary
        }
    }

    private func reload() {
        entries = LogStore.shared.snapshot()
        logFileURL = LogFile.shared.url()
    }

    private func copy() {
        copyFeedback.copy(
            entries.map(\.line).joined(separator: "\n"),
            logMessage: "Logs.copy lines=\(entries.count)"
        )
    }

    private func clear() {
        Log.ui.info("Logs.clear lines=\(entries.count)")
        LogStore.shared.clear()
        reload()
    }
}
