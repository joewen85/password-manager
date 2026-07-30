import SwiftUI

extension Binding {
    func element<Element>(
        identifiedBy id: Element.ID,
        fallback: Element
    ) -> Binding<Element>
    where Value == [Element], Element: Identifiable & Sendable, Element.ID: Sendable {
        Binding<Element>(
            get: {
                wrappedValue.first { $0.id == id } ?? fallback
            },
            set: { updatedElement in
                var elements = wrappedValue
                guard let index = elements.firstIndex(where: { $0.id == id }) else { return }
                elements[index] = updatedElement
                wrappedValue = elements
            }
        )
    }
}
