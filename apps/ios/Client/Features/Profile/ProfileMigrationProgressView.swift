import SwiftUI

struct ProfileMigrationProgressView: View {
    let stage: String
    let automationID: String

    var body: some View {
        VStack(spacing: 12) {
            CellularAutomatonLoader()
                .accessibilityIdentifier(automationID + ".loader")
            Text(verbatim: stage)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(24)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(automationID)
    }
}
