import Combine
import Foundation
import SwiftUI

struct SecretFieldDraft: Identifiable {
    let id = UUID()
    var name: String
    var value: String
}

final class SecretFieldsModel: ObservableObject {
    @Published var fields: [SecretFieldDraft]

    init(fields: [SecretFieldDraft] = [SecretFieldDraft(name: "", value: "")]) {
        self.fields = fields
    }
}

enum SecretFieldCodec {
    static func decode(_ json: String) throws -> [SecretFieldDraft] {
        guard let data = json.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: String] else {
            throw RuntimeError.bridge("Secret entry must contain flat string fields")
        }
        return object.keys.sorted().map { SecretFieldDraft(name: $0, value: object[$0] ?? "") }
    }

    static func encode(_ fields: [SecretFieldDraft]) throws -> String {
        guard !fields.isEmpty else { throw RuntimeError.bridge("Add at least one field") }
        var object: [String: String] = [:]
        for field in fields {
            let name = field.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { throw RuntimeError.bridge("Every field needs a name") }
            guard object[name] == nil else { throw RuntimeError.bridge("Field names must be unique") }
            object[name] = field.value
        }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}

struct SecretFieldsEditor: View {
    @ObservedObject var model: SecretFieldsModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            ForEach(model.fields) { field in
                let fieldBinding = binding(for: field)
                HStack(spacing: Theme.Spacing.sm) {
                    SecretFieldLayout(spacing: Theme.Spacing.sm) {
                        TextField("Field name", text: fieldBinding.name)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 44)
                        SecureField("Value", text: fieldBinding.value)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .privacySensitive()
                            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 44)
                    }
                    Button {
                        model.fields.removeAll { $0.id == field.id }
                    } label: {
                        Image(systemName: "xmark")
                            .font(Theme.Fonts.captionMd)
                            .frame(width: 44, height: 44, alignment: .trailing)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Remove field")
                    .disabled(model.fields.count == 1)
                }
                if field.id != model.fields.last?.id { Divider() }
            }
            RequestPillButton(title: String(localized: "Add field"), isPrimary: false) {
                model.fields.append(SecretFieldDraft(name: "", value: ""))
            }
        }
    }

    private func binding(for field: SecretFieldDraft) -> Binding<SecretFieldDraft> {
        Binding(
            get: { model.fields.first { $0.id == field.id } ?? field },
            set: { updated in
                guard let index = model.fields.firstIndex(where: { $0.id == field.id }) else { return }
                model.fields[index] = updated
            }
        )
    }
}

struct SecretFieldLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? subviews.map { $0.sizeThatFits(.unspecified).width }.reduce(0, +) + spacing
        let widths = fieldWidths(width)
        let height = zip(subviews, widths).map { subview, width in
            subview.sizeThatFits(ProposedViewSize(width: width, height: proposal.height)).height
        }.max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        for (subview, width) in zip(subviews, fieldWidths(bounds.width)) {
            subview.place(
                at: CGPoint(x: x, y: bounds.midY),
                anchor: .leading,
                proposal: ProposedViewSize(width: width, height: bounds.height)
            )
            x += width + spacing
        }
    }

    private func fieldWidths(_ width: CGFloat) -> [CGFloat] {
        let availableWidth = max(0, width - spacing)
        return [availableWidth / 3, availableWidth * 2 / 3]
    }
}
