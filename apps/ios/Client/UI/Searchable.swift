import SwiftUI
import UIKit

extension View {
    func oxSearchable(
        text: Binding<String>,
        isPresented: Binding<Bool>? = nil,
        placement: SearchFieldPlacement = .automatic,
        prompt: Text = Text("Search"),
        accessibilityIdentifier: String
    ) -> some View {
        modifier(SearchableModifier(
            text: text,
            isPresented: isPresented,
            placement: placement,
            prompt: prompt,
            accessibilityIdentifier: accessibilityIdentifier
        ))
    }
}

private struct SearchableModifier: ViewModifier {
    @Binding var text: String
    let isPresented: Binding<Bool>?
    let placement: SearchFieldPlacement
    let prompt: Text
    let accessibilityIdentifier: String
    @State private var presented = false

    func body(content: Content) -> some View {
        content
            .searchable(text: $text, isPresented: isPresented ?? $presented, placement: placement, prompt: prompt)
            .background(SearchFieldIdentifier(identifier: accessibilityIdentifier).frame(width: 0, height: 0))
    }
}

private struct SearchFieldIdentifier: UIViewRepresentable {
    let identifier: String

    func makeUIView(context: Context) -> Marker {
        Marker()
    }

    func updateUIView(_ view: Marker, context: Context) {
        view.identifier = identifier
        DispatchQueue.main.async { view.identifySearchField() }
    }

    final class Marker: UIView {
        var identifier = ""

        override func didMoveToWindow() {
            super.didMoveToWindow()
            DispatchQueue.main.async { self.identifySearchField() }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            identifySearchField()
        }

        func identifySearchField() {
            guard window != nil else { return }
            var ancestor = superview
            while let view = ancestor, !(view is UIWindow) {
                let fields = searchFields(in: view)
                if fields.count == 1 {
                    fields[0].accessibilityIdentifier = identifier
                    return
                }
                guard fields.isEmpty else { return }
                ancestor = view.superview
            }
        }

        private func searchFields(in view: UIView) -> [UISearchTextField] {
            if let field = view as? UISearchTextField { return [field] }
            return view.subviews.flatMap { searchFields(in: $0) }
        }
    }
}
