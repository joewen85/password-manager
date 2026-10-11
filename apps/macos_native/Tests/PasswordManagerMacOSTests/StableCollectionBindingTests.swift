import SwiftUI
import Testing
@testable import PasswordManagerMacOSApp

struct StableCollectionBindingTests {
    @Test
    @MainActor
    func deletedFieldTemplateBindingReturnsFallback() {
        let field = FieldTemplate(id: "field-1", name: "Owner")
        var fields = [field]
        let fieldsBinding = Binding(
            get: { fields },
            set: { fields = $0 }
        )
        let fieldBinding = fieldsBinding.element(identifiedBy: field.id, fallback: field)

        fields.removeAll()

        #expect(fieldBinding.wrappedValue == field)
    }

    @Test
    @MainActor
    func deletedCustomFieldBindingIgnoresStaleWrites() {
        let field = CustomField(id: "field-1", name: "Owner", value: "Alice")
        var fields = [field]
        let fieldsBinding = Binding(
            get: { fields },
            set: { fields = $0 }
        )
        let fieldBinding = fieldsBinding.element(identifiedBy: field.id, fallback: field)

        fields.removeAll()
        fieldBinding.wrappedValue = CustomField(id: field.id, name: "Owner", value: "Bob")

        #expect(fields.isEmpty)
    }

    @Test
    @MainActor
    func reorderedServiceAccountBindingUpdatesMatchingID() {
        let first = ServiceAccount(username: "first")
        let second = ServiceAccount(username: "second")
        var accounts = [first, second]
        let accountsBinding = Binding(
            get: { accounts },
            set: { accounts = $0 }
        )
        let firstBinding = accountsBinding.element(identifiedBy: first.id, fallback: first)

        accounts.swapAt(0, 1)
        var updated = firstBinding.wrappedValue
        updated.username = "updated"
        firstBinding.wrappedValue = updated

        #expect(accounts[0] == second)
        #expect(accounts[1].id == first.id)
        #expect(accounts[1].username == "updated")
    }
}
