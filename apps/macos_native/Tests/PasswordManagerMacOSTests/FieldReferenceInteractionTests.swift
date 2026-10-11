import Foundation
import Testing
@testable import PasswordManagerMacOSApp

@Suite("Field reference interaction")
struct FieldReferenceInteractionTests {
    @Test("Modern field references are editable while legacy entry references stay read-only")
    func modernAndLegacyTemplateEditingPolicy() {
        let fieldReference = FieldTemplate(
            id: "source-owner",
            name: "Owner login",
            valueType: "fieldReference",
            targetCategory: "Accounts",
            targetFieldId: "target-login"
        )
        let legacyReference = FieldTemplate(
            id: "legacy-owner",
            name: "Legacy owner",
            valueType: "entryReference",
            targetCategory: "Accounts"
        )
        let template = CategoryTemplate(category: "Servers", fields: [fieldReference, legacyReference])

        #expect(customFieldSemantics(
            field: CustomField(templateFieldId: fieldReference.id, name: fieldReference.name),
            template: template
        ).semantic == .fieldReference)
        #expect(isEditableCategoryFieldType("fieldReference"))
        #expect(!isEditableCategoryFieldType("entryReference"))

        let created = newCategoryTemplateField(
            name: " Owner login ",
            valueType: "fieldReference",
            targetCategory: " Accounts ",
            targetFieldId: "target-login"
        )
        #expect(created.name == "Owner login")
        #expect(created.targetCategory == "Accounts")
        #expect(created.targetFieldId == "target-login")
    }

    @Test("Target field candidates are text-only and reject direct self-reference")
    func targetFieldCandidatesAndValidation() {
        let source = FieldTemplate(
            id: "source-owner",
            name: "Owner login",
            valueType: "fieldReference",
            targetCategory: "Accounts",
            targetFieldId: "target-login"
        )
        let targetLogin = FieldTemplate(id: "target-login", name: "Login")
        let templates = [
            CategoryTemplate(category: "Servers", fields: [source]),
            CategoryTemplate(category: "Accounts", fields: [
                FieldTemplate(id: "name", name: "名称"),
                targetLogin,
                FieldTemplate(id: "nested", name: "Nested", valueType: "fieldReference"),
                FieldTemplate(id: "legacy", name: "Legacy", valueType: "entryReference")
            ])
        ]

        #expect(fieldReferenceTargetFieldCandidates(
            sourceCategory: "Servers",
            sourceField: source,
            templates: templates
        ).map(\.id) == ["name", targetLogin.id])
        #expect(fieldReferenceTemplateConfigurationIsValid(
            sourceCategory: "Servers",
            sourceField: source,
            templates: templates
        ))

        var nameReference = source
        nameReference.targetFieldId = "name"
        #expect(fieldReferenceTemplateConfigurationIsValid(
            sourceCategory: "Servers",
            sourceField: nameReference,
            templates: templates
        ))

        var selfReference = source
        selfReference.targetCategory = " servers "
        selfReference.targetFieldId = source.id
        #expect(!fieldReferenceTemplateConfigurationIsValid(
            sourceCategory: "Servers",
            sourceField: selfReference,
            templates: [CategoryTemplate(category: "Servers", fields: [selfReference])]
        ))
    }

    @Test("Prospective same-category templates expose other draft text fields")
    func prospectiveSameCategoryTemplateCandidates() {
        let email = newCategoryTemplateField(name: "Email")
        let alias = newCategoryTemplateField(
            name: "Alias",
            valueType: "fieldReference",
            targetCategory: "Servers",
            targetFieldId: email.id
        )
        let template = CategoryTemplate(
            category: "Servers",
            fields: CategoryTemplate.defaultCategoryFields() + [email, alias]
        )

        #expect(fieldReferenceTargetFieldCandidates(
            sourceCategory: "Servers",
            sourceField: alias,
            templates: [template]
        ).map(\.id).contains(email.id))
        #expect(fieldReferenceTemplateConfigurationIsValid(
            sourceCategory: "Servers",
            sourceField: alias,
            templates: [template]
        ))

        var selfReference = alias
        selfReference.targetFieldId = alias.id
        #expect(!fieldReferenceTemplateConfigurationIsValid(
            sourceCategory: "Servers",
            sourceField: selfReference,
            templates: [template]
        ))
    }

    @Test("All nine states use safe text and route repair to the correct editor")
    func nineStatePresentationAndRepairRouting() {
        let target = FieldReferenceTarget(
            entryID: "opaque-target-id",
            entryLabel: "Primary account",
            entryCategory: "Accounts",
            fieldID: "target-login",
            fieldName: "Login",
            fieldValue: "private-resolved-value"
        )
        let cases: [(FieldReferenceStatus, FieldReferenceActionDestination)] = [
            (.empty, .entrySelection),
            (.invalidConfiguration, .categoryFields),
            (.missing, .entrySelection),
            (.deleted, .entrySelection),
            (.categoryMismatch, .entrySelection),
            (.targetFieldMissing, .categoryFields),
            (.targetFieldUnsupported, .categoryFields),
            (.targetFieldEmpty, .entrySelection),
            (.resolved, .entrySelection)
        ]

        for (status, destination) in cases {
            let resolution = FieldReferenceResolution(
                status: status,
                target: status == .resolved ? target : nil
            )
            let presentation = fieldReferencePresentation(resolution)
            #expect(presentation.actionDestination == destination)
            #expect(!presentation.text.contains(target.entryID))
            #expect(!presentation.text.contains(target.fieldValue))
        }
        #expect(fieldReferenceResolvedValue(FieldReferenceResolution(status: .resolved, target: target)) == target.fieldValue)
        #expect(fieldReferenceResolvedValue(FieldReferenceResolution(status: .targetFieldEmpty)) == nil)
    }

    @Test("Entry drafts create editable instances for both reference generations")
    func entryDraftCreatesReferenceInstances() {
        let modern = FieldTemplate(
            id: "modern",
            name: "Modern",
            valueType: "fieldReference",
            targetCategory: "Accounts",
            targetFieldId: "login"
        )
        let legacy = FieldTemplate(
            id: "legacy",
            name: "Legacy",
            valueType: "entryReference",
            targetCategory: "Accounts"
        )
        let draft = EntryDraft(category: "Servers", templateFields: [modern, legacy])

        #expect(draft.customFields.map(\.templateFieldId) == [modern.id, legacy.id])
        #expect(draft.protectedCustomFieldIds.isEmpty)
    }

    @MainActor
    @Test("Store creates, updates, and resolves modern field references without losing target metadata")
    func storeModernFieldReferenceLifecycle() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PasswordManagerMacOSFieldReferenceInteraction-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = VaultStore(
            repository: FileVaultRepository(baseDirectory: directory),
            syncSettingsRepository: nil
        )
        #expect(store.setupMasterPassword("test-password", confirmation: "test-password"))
        #expect(store.addCategory("Accounts"))
        let targetField = FieldTemplate(id: "target-login", name: "Login")
        #expect(store.updateCategoryTemplate("Accounts", fields: [targetField]))
        #expect(store.addCategory("Servers"))
        let sourceField = FieldTemplate(
            id: "source-owner",
            name: "Owner login",
            valueType: "fieldReference",
            targetCategory: "Accounts",
            targetFieldId: targetField.id
        )
        #expect(store.updateCategoryTemplate("Servers", fields: [sourceField]))

        var targetDraft = EntryDraft(
            category: "Accounts",
            templateFields: try #require(store.categoryTemplates.first { $0.category == "Accounts" }?.fields)
        )
        targetDraft.label = "Primary account"
        let targetIndex = try #require(targetDraft.customFields.firstIndex {
            $0.templateFieldId == targetField.id
        })
        targetDraft.customFields[targetIndex].value = "alice@example.com"
        store.upsert(targetDraft, editing: nil)

        var sourceDraft = EntryDraft(
            category: "Servers",
            templateFields: try #require(store.categoryTemplates.first { $0.category == "Servers" }?.fields)
        )
        sourceDraft.label = "Gateway"
        store.upsert(sourceDraft, editing: nil)
        let targetEntry = try #require(store.entries.first { $0.label == targetDraft.label })
        let sourceEntry = try #require(store.entries.first { $0.label == sourceDraft.label })
        let sourceValue = try #require(sourceEntry.customFields.first { $0.templateFieldId == sourceField.id })

        #expect(store.updateEntryReference(
            entryID: sourceEntry.id,
            fieldID: sourceValue.id,
            targetID: targetEntry.id
        ))
        let updatedSource = try #require(store.entries.first { $0.id == sourceEntry.id })
        let updatedValue = try #require(updatedSource.customFields.first { $0.id == sourceValue.id })
        #expect(resolveFieldReference(
            sourceEntry: updatedSource,
            field: updatedValue,
            categoryTemplates: store.categoryTemplates,
            entries: store.entries
        )?.target?.fieldValue == "alice@example.com")

        var renamed = sourceField
        renamed.name = "Primary owner login"
        #expect(store.updateCategoryTemplate("Servers", fields: [renamed]))
        #expect(store.categoryTemplates.first { $0.category == "Servers" }?.fields.first {
            $0.id == sourceField.id
        }?.targetFieldId == targetField.id)

        var invalid = renamed
        invalid.targetFieldId = ""
        let beforeInvalidSave = store.categoryTemplates.first { $0.category == "Servers" }
        #expect(!store.updateCategoryTemplate("Servers", fields: [invalid]))
        #expect(store.categoryTemplates.first { $0.category == "Servers" } == beforeInvalidSave)
    }
}
