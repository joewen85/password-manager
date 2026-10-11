import Foundation
import Testing
@testable import PasswordManageriOSCore

@Suite("Field reference contract")
struct FieldReferenceContractTests {
    @Test("Field-level reference metadata survives shared fixture and container round trips")
    func fieldReferenceMetadataRoundTrips() throws {
        let repository = FileVaultRepository()
        let snapshot = try repository.decodeSnapshot(fixtureData("snapshot-field-reference.json"))
        let sourceEntry = try #require(snapshot.entries.first { $0.id == "server_source_01" })
        let sourceTemplate = try #require(snapshot.categoryTemplates.first { $0.category == "Servers" })
        let sourceField = try #require(sourceTemplate.fields.first { $0.id == "source_owner_email_field" })

        #expect(sourceField.valueType == "fieldReference")
        #expect(sourceField.targetCategory == "Accounts")
        #expect(sourceField.targetFieldId == "target_email_field")
        #expect(sourceEntry.customFields.first?.templateFieldId == sourceField.id)
        #expect(sourceEntry.customFields.first?.value == "account_target_01")
        #expect(try repository.decodeSnapshot(repository.encodeSnapshot(snapshot)) == snapshot)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let scopedExport = ScopedVaultExport(
            scope: .item,
            exportedAt: Date(timeIntervalSince1970: 1_775_000_000),
            item: sourceEntry,
            category: nil,
            items: nil,
            categoryTemplates: [sourceTemplate]
        )
        let syncPayload = VaultSyncPayload(
            exportedAt: Date(timeIntervalSince1970: 1_775_000_001),
            deviceId: "ios-contract",
            revision: 7,
            snapshot: snapshot
        )

        let scopedField = try decoder.decode(
            ScopedVaultExport.self,
            from: encoder.encode(scopedExport)
        ).categoryTemplates.first?.fields.first
        let syncField = try decoder.decode(
            VaultSyncPayload.self,
            from: encoder.encode(syncPayload)
        ).snapshot.categoryTemplates.first { $0.category == "Servers" }?.fields.first

        for decodedField in [scopedField, syncField] {
            #expect(decodedField?.valueType == "fieldReference")
            #expect(decodedField?.targetCategory == "Accounts")
            #expect(decodedField?.targetFieldId == "target_email_field")
        }
    }

    @Test("Target field IDs default to empty and unknown field types preserve them")
    func targetFieldIdCompatibilityDefaults() throws {
        let fields = try JSONDecoder().decode(
            [FieldTemplate].self,
            from: Data(
                #"[{"id":"legacy","name":"Legacy"},{"id":"future","name":"Future","valueType":"futureFieldReferenceV2","targetCategory":"Accounts","targetFieldId":"opaque-target-field"}]"#.utf8
            )
        )

        #expect(FieldTemplate(name: "New").targetFieldId == "")
        #expect(fields[0].targetFieldId == "")
        #expect(fields[1].targetFieldId == "opaque-target-field")
        #expect(try JSONDecoder().decode([FieldTemplate].self, from: JSONEncoder().encode(fields)) == fields)
    }

    @Test("Shared contract fixtures round trip semantically")
    func sharedContractFixturesRoundTripSemantically() throws {
        let repository = FileVaultRepository()
        let referenceSnapshot = try repository.decodeSnapshot(fixtureData("snapshot-entry-reference.json"))
        let sourceEntry = try #require(referenceSnapshot.entries.first { $0.id == "22222222-2222-4222-8222-222222222222" })
        #expect(referenceSnapshot.entries.first?.id == "harmony_target_01")
        #expect(sourceEntry.customFields.first?.id == "harmony_field_01")
        #expect(sourceEntry.customFields.first?.templateFieldId == "44444444-4444-4444-8444-444444444444")
        #expect(sourceEntry.customFields.first?.value == "harmony_target_01")
        #expect(try repository.decodeSnapshot(repository.encodeSnapshot(referenceSnapshot)) == referenceSnapshot)

        let legacySnapshot = try repository.decodeSnapshot(fixtureData("snapshot-legacy-text.json"))
        #expect(legacySnapshot.categoryTemplates.first?.fields.first?.id == "template_owner_team")
        #expect(legacySnapshot.categoryTemplates.first?.fields.first?.valueType == "text")
        #expect(legacySnapshot.entries.first?.customFields.first?.templateFieldId == "")
        #expect(try repository.decodeSnapshot(repository.encodeSnapshot(legacySnapshot)) == legacySnapshot)

        let emptySlugSnapshot = try repository.decodeSnapshot(fixtureData("snapshot-legacy-empty-slug.json"))
        #expect(emptySlugSnapshot.categoryTemplates.first?.fields.map(\.id) == [
            "template_u_f09f9880",
            "template_u_212121"
        ])
        #expect(try repository.decodeSnapshot(repository.encodeSnapshot(emptySlugSnapshot)) == emptySlugSnapshot)

        let unknownSnapshot = try repository.decodeSnapshot(fixtureData("snapshot-unknown-value-type.json"))
        #expect(unknownSnapshot.categoryTemplates.first?.fields.first?.valueType == "futureLink")
        #expect(try repository.decodeSnapshot(repository.encodeSnapshot(unknownSnapshot)) == unknownSnapshot)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        for name in ["scoped-item-entry-reference.json", "scoped-category-entry-reference.json"] {
            let scopedExport = try decoder.decode(ScopedVaultExport.self, from: fixtureData(name))
            #expect(scopedExport.version == 2)
            #expect(scopedExport.categoryTemplates.first?.fields.first?.valueType == "entryReference")
            #expect(scopedExport.categoryTemplates.first?.fields.first?.targetCategory == "Accounts")
            #expect(scopedExport.item?.id != "harmony_target_01")
            #expect(scopedExport.items?.contains { $0.id == "harmony_target_01" } != true)
            #expect(try decoder.decode(ScopedVaultExport.self, from: encoder.encode(scopedExport)) == scopedExport)
        }
    }

    @Test("Legacy defaults and unknown field types round trip without loss")
    func legacyDefaultsAndUnknownTypesRoundTrip() throws {
        let data = Data(
            #"""
            [
              {"name":" Owner / 账户 "},
              {
                "id":"opaque-template:future",
                "name":"Future",
                "valueType":"futureReference",
                "targetCategory":"Future Targets"
              }
            ]
            """#.utf8
        )

        let fields = try JSONDecoder().decode([FieldTemplate].self, from: data)

        #expect(fields[0].id == "template_owner_账户")
        #expect(fields[0].valueType == "text")
        #expect(fields[0].targetCategory == "")
        #expect(fields[1].id == "opaque-template:future")
        #expect(fields[1].valueType == "futureReference")
        #expect(fields[1].targetCategory == "Future Targets")

        let encoded = try JSONEncoder().encode(fields)
        let roundTripped = try JSONDecoder().decode([FieldTemplate].self, from: encoded)
        #expect(roundTripped == fields)

        let legacyCustomField = try JSONDecoder().decode(
            CustomField.self,
            from: Data(#"{"id":"harmony-field:owner","name":"Owner","value":"harmony-entry:account"}"#.utf8)
        )
        #expect(legacyCustomField.id == "harmony-field:owner")
        #expect(legacyCustomField.templateFieldId == "")
    }

    @Test("Opaque entry and custom field identifiers survive snapshot round trip")
    func opaqueIdentifiersSurviveSnapshotRoundTrip() throws {
        let repository = FileVaultRepository(
            baseDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("PasswordManageriOSOpaqueContract-\(UUID().uuidString)", isDirectory: true)
        )
        let snapshot = VaultSnapshot(
            entries: [
                VaultEntry(
                    id: "harmony-entry:server",
                    label: "Server",
                    type: .server,
                    payload: .server(ServerPayload(category: "Servers")),
                    customFields: [
                        CustomField(
                            id: "harmony-field:owner",
                            templateFieldId: "template_owner",
                            name: "Owner",
                            value: "harmony-entry:account"
                        )
                    ]
                )
            ],
            categories: ["Servers"],
            categoryTemplates: [
                CategoryTemplate(
                    category: "Servers",
                    fields: [
                        FieldTemplate(
                            id: "template_owner",
                            name: "Owner",
                            valueType: "entryReference",
                            targetCategory: "Accounts"
                        )
                    ]
                )
            ]
        )

        let decoded = try repository.decodeSnapshot(repository.encodeSnapshot(snapshot))

        #expect(decoded.entries.first?.id == "harmony-entry:server")
        #expect(decoded.entries.first?.customFields.first?.id == "harmony-field:owner")
        #expect(decoded.entries.first?.customFields.first?.templateFieldId == "template_owner")
        #expect(decoded.categoryTemplates.first?.fields.first?.valueType == "entryReference")
        #expect(decoded.categoryTemplates.first?.fields.first?.targetCategory == "Accounts")
    }

    @Test("Scoped exports use v2 and include only the source category template")
    func scopedExportsIncludeOnlySourceCategoryTemplate() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PasswordManageriOSScopedContract-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = FileVaultRepository(baseDirectory: directory)
        let entry = VaultEntry(
            id: "harmony-entry:server",
            label: "Server",
            type: .server,
            payload: .server(ServerPayload(category: "Servers")),
            customFields: [
                CustomField(
                    id: "harmony-field:owner",
                    templateFieldId: "template_owner",
                    name: "Owner",
                    value: "harmony-entry:account"
                )
            ]
        )
        let sourceTemplate = CategoryTemplate(
            category: "Servers",
            fields: [
                FieldTemplate(
                    id: "template_owner",
                    name: "Owner",
                    valueType: "entryReference",
                    targetCategory: "Accounts"
                )
            ]
        )
        let targetTemplate = CategoryTemplate(category: "Accounts")

        let exportURL = try repository.saveEntryExport(
            entry,
            categoryTemplates: [sourceTemplate, targetTemplate],
            at: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let export = try decoder.decode(ScopedVaultExport.self, from: Data(contentsOf: exportURL))

        #expect(export.version == 2)
        #expect(export.item?.id == "harmony-entry:server")
        #expect(export.item?.customFields.first?.value == "harmony-entry:account")
        #expect(export.items == nil)
        #expect(export.categoryTemplates == [sourceTemplate])

        let categoryExportURL = try repository.saveCategoryExport(
            category: "Servers",
            entries: [entry],
            categoryTemplates: [sourceTemplate, targetTemplate],
            at: Date(timeIntervalSince1970: 1_700_000_001)
        )
        let categoryExport = try decoder.decode(
            ScopedVaultExport.self,
            from: Data(contentsOf: categoryExportURL)
        )
        #expect(categoryExport.version == 2)
        #expect(categoryExport.item == nil)
        #expect(categoryExport.items?.map(\.id) == ["harmony-entry:server"])
        #expect(categoryExport.categoryTemplates == [sourceTemplate])
    }

    @Test("New identifiers are canonical lowercase UUID strings")
    func newIdentifiersAreCanonicalLowercaseUUIDStrings() {
        let entry = VaultEntry(
            label: "Entry",
            type: .credential,
            payload: .credential(CredentialPayload())
        )
        let customField = CustomField()
        let templateField = FieldTemplate(name: "Owner")

        for id in [entry.id, customField.id, templateField.id] {
            #expect(UUID(uuidString: id) != nil)
            #expect(id == id.lowercased())
        }
    }

    @Test("Version one scoped exports remain readable")
    func versionOneScopedExportsRemainReadable() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let export = try decoder.decode(
            ScopedVaultExport.self,
            from: Data(
                #"""
                {
                  "version":1,
                  "scope":"item",
                  "exportedAt":"2026-07-28T00:00:00Z"
                }
                """#.utf8
            )
        )

        #expect(export.version == 1)
        #expect(export.categoryTemplates == [])
    }

    @MainActor
    @Test("Scoped import merges templates and preserves unresolved references")
    func scopedImportMergesTemplatesAndPreservesReferences() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PasswordManageriOSScopedImportContract-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = FileVaultRepository(baseDirectory: directory)
        let store = VaultStore(repository: repository, syncSettingsRepository: nil)
        #expect(store.setupMasterPassword("test-password", confirmation: "test-password"))
        let ownerTemplate = FieldTemplate(
            id: "template_owner",
            name: "Owner",
            valueType: "entryReference",
            targetCategory: "Accounts"
        )
        let scopedExport = ScopedVaultExport(
            scope: .item,
            exportedAt: Date(timeIntervalSince1970: 1_700_000_000),
            item: VaultEntry(
                id: "harmony-entry:server",
                label: "Imported Server",
                type: .server,
                payload: .server(ServerPayload(category: "Servers")),
                customFields: [
                    CustomField(
                        id: "harmony-field:owner",
                        templateFieldId: ownerTemplate.id,
                        name: ownerTemplate.name,
                        value: "missing-target"
                    )
                ]
            ),
            category: nil,
            items: nil,
            categoryTemplates: [CategoryTemplate(category: "Servers", fields: [ownerTemplate])]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let fileName = "field-reference-import.json"
        try encoder.encode(scopedExport).write(
            to: try repository.importsDirectoryURL.appendingPathComponent(fileName)
        )

        store.importScopedExport(fileName: fileName, strategy: .keepCopy)

        let importedTemplate = try #require(store.categoryTemplates.first { $0.category == "Servers" })
        #expect(importedTemplate.fields.contains(ownerTemplate))
        let importedEntry = try #require(store.entries.first)
        #expect(importedEntry.id != "harmony-entry:server")
        #expect(importedEntry.customFields.first?.templateFieldId == "template_owner")
        #expect(importedEntry.customFields.first?.value == "missing-target")
        #expect(store.entries.count == 1)
    }

    @MainActor
    @Test("Scoped copy import remaps references to targets copied in the same batch")
    func scopedCopyImportRemapsReferencesToCopiedTargets() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PasswordManageriOSReferenceRemapTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = FileVaultRepository(baseDirectory: directory)
        let store = VaultStore(repository: repository, syncSettingsRepository: nil)
        #expect(store.setupMasterPassword("test-password", confirmation: "test-password"))

        let ownerTemplate = FieldTemplate(
            id: "template_owner",
            name: "Owner",
            valueType: "entryReference",
            targetCategory: "Accounts"
        )
        let target = VaultEntry(
            id: "source-target-id",
            label: "Imported Target",
            type: .credential,
            payload: .credential(CredentialPayload(category: "Accounts"))
        )
        let source = VaultEntry(
            id: "source-entry-id",
            label: "Imported Source",
            type: .server,
            payload: .server(ServerPayload(category: "Servers")),
            customFields: [
                CustomField(
                    id: "source-owner-field",
                    templateFieldId: ownerTemplate.id,
                    name: ownerTemplate.name,
                    value: target.id
                )
            ]
        )
        let scopedExport = ScopedVaultExport(
            scope: .category,
            exportedAt: Date(timeIntervalSince1970: 1_700_000_001),
            item: nil,
            category: "Servers",
            items: [source, target],
            categoryTemplates: [CategoryTemplate(category: "Servers", fields: [ownerTemplate])]
        )
        try writeScopedExport(scopedExport, fileName: "reference-remap.json", repository: repository)

        store.importScopedExport(fileName: "reference-remap.json", strategy: .keepCopy)

        let importedTarget = try #require(store.entries.first { $0.label == target.label })
        let importedSource = try #require(store.entries.first { $0.label == source.label })
        #expect(importedTarget.id != target.id)
        #expect(importedSource.id != source.id)
        #expect(importedSource.customFields.first?.value == importedTarget.id)
        #expect(importedSource.customFields.first?.templateFieldId == ownerTemplate.id)

        let isolatedDirectory = directory.appendingPathComponent("isolated", isDirectory: true)
        let isolatedRepository = FileVaultRepository(baseDirectory: isolatedDirectory)
        let isolatedStore = VaultStore(repository: isolatedRepository, syncSettingsRepository: nil)
        #expect(isolatedStore.setupMasterPassword("test-password", confirmation: "test-password"))
        var sourceOnlyExport = scopedExport
        sourceOnlyExport.items = [source]
        try writeScopedExport(sourceOnlyExport, fileName: "source-only.json", repository: isolatedRepository)

        isolatedStore.importScopedExport(fileName: "source-only.json", strategy: .keepCopy)

        let isolatedSource = try #require(isolatedStore.entries.first)
        #expect(isolatedSource.customFields.first?.value == target.id)
        #expect(isolatedSource.customFields.first?.templateFieldId == ownerTemplate.id)
    }

    @MainActor
    @Test("Scoped overwrite import remaps references to an existing destination ID")
    func scopedOverwriteImportRemapsReferencesToExistingDestinationID() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PasswordManageriOSExistingReferenceRemapTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = FileVaultRepository(baseDirectory: directory)
        let store = VaultStore(repository: repository, syncSettingsRepository: nil)
        #expect(store.setupMasterPassword("test-password", confirmation: "test-password"))

        let target = VaultEntry(
            id: "source-existing-target-id",
            label: "Existing Target",
            type: .credential,
            payload: .credential(CredentialPayload(category: "Accounts"))
        )
        let initialTargetExport = ScopedVaultExport(
            scope: .item,
            exportedAt: Date(timeIntervalSince1970: 1_700_000_002),
            item: target,
            category: nil,
            items: nil
        )
        try writeScopedExport(initialTargetExport, fileName: "initial-target.json", repository: repository)
        store.importScopedExport(fileName: "initial-target.json", strategy: .keepCopy)
        let existingDestination = try #require(store.entries.first { $0.label == target.label })

        let ownerTemplate = FieldTemplate(
            id: "template_owner",
            name: "Owner",
            valueType: "entryReference",
            targetCategory: "Accounts"
        )
        let source = VaultEntry(
            id: "source-for-existing-target",
            label: "Source For Existing Target",
            type: .server,
            payload: .server(ServerPayload(category: "Servers")),
            customFields: [
                CustomField(
                    id: "existing-owner-field",
                    templateFieldId: ownerTemplate.id,
                    name: ownerTemplate.name,
                    value: target.id
                )
            ]
        )
        let batchExport = ScopedVaultExport(
            scope: .category,
            exportedAt: Date(timeIntervalSince1970: 1_700_000_003),
            item: nil,
            category: "Servers",
            items: [source, target],
            categoryTemplates: [CategoryTemplate(category: "Servers", fields: [ownerTemplate])]
        )
        try writeScopedExport(batchExport, fileName: "existing-target-batch.json", repository: repository)

        store.importScopedExport(fileName: "existing-target-batch.json", strategy: .overwrite)

        let importedSource = try #require(store.entries.first { $0.label == source.label })
        let retainedDestination = try #require(store.entries.first { $0.label == target.label })
        #expect(retainedDestination.id == existingDestination.id)
        #expect(importedSource.customFields.first?.value == existingDestination.id)
        #expect(importedSource.customFields.first?.templateFieldId == ownerTemplate.id)
    }

    @Test("Template application protects values matched by template id before legacy name")
    func templateApplicationBindsByTemplateIdBeforeName() {
        let template = FieldTemplate(
            id: "template_owner",
            name: "Renamed Owner",
            valueType: "entryReference",
            targetCategory: "Accounts"
        )
        var draft = EntryDraft()
        draft.customFields = [
            CustomField(
                id: "harmony-field:owner",
                templateFieldId: "template_owner",
                name: "Owner",
                value: "harmony-entry:account"
            )
        ]

        draft.configureTemplateFields([template])

        #expect(draft.customFields == [
            CustomField(
                id: "harmony-field:owner",
                templateFieldId: "template_owner",
                name: "Owner",
                value: "harmony-entry:account"
            )
        ])
    }

    @Test("Entry drafts preserve protected template fields across editing and category changes")
    func entryDraftPreservesProtectedTemplateFields() throws {
        let textTemplate = FieldTemplate(id: "template_text", name: "Text")
        let referenceTemplate = FieldTemplate(
            id: "template_owner",
            name: "Owner",
            valueType: "entryReference",
            targetCategory: "Accounts"
        )
        let unknownTemplate = FieldTemplate(
            id: "template_future",
            name: "Future",
            valueType: "futureRelationV3",
            targetCategory: "Targets"
        )
        let referenceField = CustomField(
            id: "opaque-field:owner",
            templateFieldId: referenceTemplate.id,
            name: " Owner ",
            value: " opaque-target:account "
        )
        let unknownField = CustomField(
            id: "opaque-field:future",
            templateFieldId: unknownTemplate.id,
            name: " Future ",
            value: " future-value "
        )
        let textField = CustomField(
            id: "opaque-field:text",
            templateFieldId: textTemplate.id,
            name: "Text",
            value: " old text "
        )
        let templates = [textTemplate, referenceTemplate, unknownTemplate]

        var draft = EntryDraft()
        draft.customFields = [referenceField, textField, unknownField]
        draft.configureTemplateFields(templates)

        #expect(draft.protectedCustomFieldIds == [referenceField.id, unknownField.id])
        let textIndex = try #require(draft.customFields.firstIndex { $0.id == textField.id })
        draft.customFields[textIndex].value = " edited text "
        let normalized = draft.normalizedCustomFields
        #expect(normalized.first { $0.id == textField.id }?.value == "edited text")
        #expect(normalized.first { $0.id == referenceField.id } == referenceField)
        #expect(normalized.first { $0.id == unknownField.id } == unknownField)

        draft.configureTemplateFields(templates)
        draft.configureTemplateFields([FieldTemplate(id: "template_other", name: "Other")])
        draft.configureTemplateFields(templates)

        #expect(draft.normalizedCustomFields.filter { $0.id == referenceField.id } == [referenceField])
        #expect(draft.normalizedCustomFields.filter { $0.id == unknownField.id } == [unknownField])

        var newDraft = EntryDraft()
        newDraft.configureTemplateFields(templates)
        #expect(newDraft.customFields.map(\.templateFieldId) == [textTemplate.id, referenceTemplate.id])
        #expect(newDraft.protectedCustomFieldIds == [newDraft.customFields[1].id])
        #expect(newDraft.hiddenCustomFieldIds.isEmpty)
    }

    private func fixtureData(_ name: String) throws -> Data {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try Data(contentsOf: repositoryRoot.appendingPathComponent("fixtures/vault-contract/v1/\(name)"))
    }

    private func writeScopedExport(
        _ scopedExport: ScopedVaultExport,
        fileName: String,
        repository: FileVaultRepository
    ) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(scopedExport).write(
            to: try repository.importsDirectoryURL.appendingPathComponent(fileName)
        )
    }
}
