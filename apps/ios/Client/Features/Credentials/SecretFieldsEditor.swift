import Foundation
import SwiftUI

struct SecretFieldDraft: Identifiable {
    let id = UUID()
    var name: String
    var value: String
}

enum SecretFieldCodec {
    static func decode(_ json: String) throws -> [SecretFieldDraft] {
        guard let data = json.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: String] else {
            throw RuntimeError.bridge("Secret entry must contain flat string fields")
        }
        return object.keys.sorted().map { SecretFieldDraft(name: $0, value: object[$0] ?? "") }
    }
}

extension SecretType {
    var title: LocalizedStringKey {
        switch self {
        case .account: "Login"
        case .apiKey: "API key"
        case .token: "Token"
        }
    }

    func fieldTitle(_ field: String) -> LocalizedStringKey {
        switch field {
        case "username": "Username"
        case "password": "Password"
        case "apiKey": "API key"
        default: "Token"
        }
    }

    func isComplete(_ values: [String: String]) -> Bool {
        fields.allSatisfy { !(values[$0] ?? "").isEmpty }
    }
}

struct SecretTypedFieldsEditor: View {
    let type: SecretType
    @Binding var values: [String: String]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(type.fields.enumerated()), id: \.element) { index, field in
                if index > 0 { Divider() }
                SecretFieldInput(type: type, field: field, values: $values)
                    .frame(minHeight: 44)
            }
        }
    }
}

struct SecretFieldInput: View {
    let type: SecretType
    let field: String
    @Binding var values: [String: String]

    var body: some View {
        input
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .accessibilityIdentifier("secret-entry-field-\(field)")
    }

    @ViewBuilder
    private var input: some View {
        let binding = Binding(get: { values[field] ?? "" }, set: { values[field] = $0 })
        if field == "username" {
            TextField(type.fieldTitle(field), text: binding)
                .textContentType(.username)
                .keyboardType(.emailAddress)
        } else {
            SecureField(type.fieldTitle(field), text: binding)
                .textContentType(field == "password" ? .password : nil)
                .privacySensitive()
        }
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
