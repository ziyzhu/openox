import SwiftUI

struct CanvasInteractionView: View {
    let canvas: OxCanvas

    var body: some View {
        if let interaction = canvas.interaction {
            Group {
                switch interaction {
                case .approval(let request):
                    PermissionRequestCard(request: PermissionRequest(request)) { answer in
                        canvas.resolveInteraction(id: request.id, value: .string(answer))
                    }
                case .choice(let id, let prompt, let options):
                    RequestCard(title: canvas.title, message: prompt) {
                        ForEach(options, id: \.self) { option in
                            Button(option) { canvas.resolveInteraction(id: id, value: .string(option)) }
                                .buttonStyle(.bordered)
                        }
                    }
                    .padding()
                    .background(.regularMaterial)
                case .control(let id, let control, let service):
                    ServiceControlView(
                        control: control,
                        signIn: { _ in await canvas.performControl(control, service: service) != nil },
                        completeBotControl: { _, _ in await canvas.performControl(control, service: service) != nil },
                        completePayment: { _, _ in await canvas.performControl(control, service: service) },
                        onResolved: { canvas.resolveInteraction(id: id, value: $0) }
                    )
                }
            }
            .id(interaction.id)
            .padding(Theme.Spacing.md)
        }
    }
}
