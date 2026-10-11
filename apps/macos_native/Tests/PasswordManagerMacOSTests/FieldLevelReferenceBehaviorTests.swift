import Foundation
import Testing
@testable import PasswordManagerMacOSApp

@Suite("Field-level reference behavior")
struct FieldLevelReferenceBehaviorTests {
    @Test("Resolution follows the field-reference status precedence")
    func resolutionStatusPrecedence() throws {
        var scenario = FieldReferenceScenario()
        scenario.sourceValue = "  \n"
        scenario.sourceField.targetCategory = ""
        #expect(scenario.resolution()?.status == .empty)

        scenario = FieldReferenceScenario()
        scenario.sourceField.targetCategory = ""
        #expect(scenario.resolution()?.status == .invalidConfiguration)

        scenario = FieldReferenceScenario()
        scenario.sourceField.targetFieldId = "   "
        #expect(scenario.resolution()?.status == .invalidConfiguration)

        scenario = FieldReferenceScenario()
        scenario.sourceCategory = " accounts "
        scenario.sourceField.id = scenario.targetField.id
        scenario.sourceField.targetCategory = "ACCOUNTS"
        scenario.sourceField.targetFieldId = scenario.targetField.id
        scenario.sourceValue = "source-entry"
        #expect(scenario.resolution()?.status == .invalidConfiguration)

        scenario = FieldReferenceScenario()
        scenario.sourceValue = "Target-Entry"
        #expect(scenario.resolution()?.status == .missing)

        scenario = FieldReferenceScenario()
        scenario.targetEntry = makeFieldReferenceTargetEntry(
            category: "Archive",
            isDeleted: true
        )
        let deleted = try #require(scenario.resolution())
        #expect(deleted.status == .deleted)
        #expect(deleted.target?.fieldID == "target-login")
        #expect(deleted.target?.fieldName.isEmpty == true)
        #expect(deleted.target?.fieldValue.isEmpty == true)
        #expect(!String(reflecting: deleted).contains("private-target-value"))

        scenario = FieldReferenceScenario()
        scenario.targetEntry = makeFieldReferenceTargetEntry(category: "Archive")
        let mismatch = try #require(scenario.resolution())
        #expect(mismatch.status == .categoryMismatch)
        #expect(mismatch.target?.fieldValue.isEmpty == true)
        #expect(!String(reflecting: mismatch).contains("private-target-value"))

        scenario = FieldReferenceScenario()
        scenario.includeTargetTemplate = false
        let fieldMissing = try #require(scenario.resolution())
        #expect(fieldMissing.status == .targetFieldMissing)
        #expect(fieldMissing.target?.fieldName.isEmpty == true)
        #expect(fieldMissing.target?.fieldValue.isEmpty == true)

        scenario = FieldReferenceScenario()
        scenario.sourceField.targetFieldId = "TARGET-login"
        #expect(scenario.resolution()?.status == .targetFieldMissing)

        scenario = FieldReferenceScenario()
        scenario.targetField.valueType = "fieldReference"
        let unsupported = try #require(scenario.resolution())
        #expect(unsupported.status == .targetFieldUnsupported)
        #expect(unsupported.target?.fieldName == "Login alias")
        #expect(unsupported.target?.fieldValue.isEmpty == true)

        scenario = FieldReferenceScenario()
        scenario.targetEntry = makeFieldReferenceTargetEntry(customFields: [])
        let fieldEmpty = try #require(scenario.resolution())
        #expect(fieldEmpty.status == .targetFieldEmpty)
        #expect(fieldEmpty.target?.fieldName == "Login alias")
        #expect(fieldEmpty.target?.fieldValue.isEmpty == true)

        scenario = FieldReferenceScenario()
        scenario.targetEntry = makeFieldReferenceTargetEntry(customFields: [
            CustomField(
                templateFieldId: "different-id",
                name: scenario.targetField.name,
                value: "name-must-not-override-an-explicit-binding"
            )
        ])
        #expect(scenario.resolution()?.status == .targetFieldEmpty)

        scenario = FieldReferenceScenario()
        scenario.targetEntry = makeFieldReferenceTargetEntry(customFields: [
            CustomField(
                templateFieldId: scenario.targetField.id,
                name: scenario.targetField.name,
                value: " \n "
            )
        ])
        #expect(scenario.resolution()?.status == .targetFieldEmpty)
    }

    @Test("Resolved projection is minimal and matching is exact where required")
    func resolvedProjectionAndExactMatching() throws {
        var scenario = FieldReferenceScenario()
        scenario.sourceField.targetCategory = " accounts "
        scenario.targetEntry = makeFieldReferenceTargetEntry(category: " ACCOUNTS ")
        let resolution = try #require(scenario.resolution())

        #expect(resolution.status == .resolved)
        #expect(resolution.target == FieldReferenceTarget(
            entryID: "target-entry",
            entryLabel: "Payroll Account",
            entryCategory: "ACCOUNTS",
            fieldID: "target-login",
            fieldName: "Login alias",
            fieldValue: "private-target-value"
        ))
        let projection = try #require(resolution.target)
        #expect(Mirror(reflecting: projection).children.compactMap(\.label) == [
            "entryID", "entryLabel", "entryCategory", "fieldID", "fieldName", "fieldValue"
        ])
        #expect(!String(reflecting: projection).contains("target-password-secret"))

        scenario.targetEntry = makeFieldReferenceTargetEntry(customFields: [
            CustomField(
                templateFieldId: "",
                name: " login ALIAS ",
                value: "legacy-target-value"
            )
        ])
        #expect(scenario.resolution()?.target?.fieldValue == "legacy-target-value")

        scenario.sourceValue = " target-entry "
        #expect(scenario.resolution()?.status == .missing)

        scenario = FieldReferenceScenario()
        scenario.sourceField.valueType = "FieldReference"
        #expect(scenario.resolution() == nil)
    }

    @Test("The built-in entry name field resolves from the target label")
    func builtInEntryNameTarget() throws {
        var scenario = FieldReferenceScenario()
        scenario.targetField = try #require(CategoryTemplate.defaultCategoryFields().first { $0.name == "名称" })
        scenario.sourceField.targetFieldId = scenario.targetField.id
        scenario.targetEntry = makeFieldReferenceTargetEntry(customFields: [])

        let resolution = try #require(scenario.resolution())
        #expect(resolution.status == .resolved)
        #expect(resolution.target?.entryLabel == "Payroll Account")
        #expect(resolution.target?.fieldID == scenario.targetField.id)
        #expect(resolution.target?.fieldName == "名称")
        #expect(resolution.target?.fieldValue == "Payroll Account")
    }

    @Test("Search projection exposes only resolved safe terms and preserves entry references")
    func safeSearchProjection() throws {
        let fieldReference = makeFieldReferenceSourceField()
        let entryReference = FieldTemplate(
            id: "source-owner",
            name: "Owner",
            valueType: "entryReference",
            targetCategory: "Accounts"
        )
        let source = makeFieldReferenceSourceEntry(
            fields: [
                CustomField(
                    templateFieldId: fieldReference.id,
                    name: fieldReference.name,
                    value: "target-entry"
                ),
                CustomField(
                    templateFieldId: entryReference.id,
                    name: entryReference.name,
                    value: "target-entry"
                )
            ]
        )
        let target = makeFieldReferenceTargetEntry()
        let templates = [
            CategoryTemplate(category: "Servers", fields: [fieldReference, entryReference]),
            CategoryTemplate(category: "Accounts", fields: [makeFieldReferenceTargetField()])
        ]

        let projected = source.withFieldReferenceSearchProjection(
            categoryTemplates: templates,
            entries: [source, target]
        )

        #expect(projected.customFields[0].value == "Payroll Account Accounts Login alias")
        #expect(projected.customFields[1].value == "Payroll Account Accounts")
        for forbidden in [
            "private-target-value",
            "target-entry",
            "target-login",
            "target-password-secret"
        ] {
            #expect(!projected.customFields.map(\.value).joined(separator: " ").contains(forbidden))
        }

        let unresolved = source.withFieldReferenceSearchProjection(
            categoryTemplates: templates,
            entries: [source]
        )
        #expect(unresolved.customFields[0].value.isEmpty)
    }

    @Test("Rename, dependency, and import helpers keep opaque IDs stable")
    func referenceOperations() {
        let fieldReference = makeFieldReferenceSourceField(targetCategory: " accounts ")
        let entryReference = FieldTemplate(
            id: "legacy-entry-reference",
            name: "Owner",
            valueType: "entryReference",
            targetCategory: " accounts "
        )
        let futureReference = FieldTemplate(
            id: "future-reference",
            name: "Future",
            valueType: "futureFieldReference",
            targetCategory: " accounts ",
            targetFieldId: "future-target"
        )
        let templates = [
            CategoryTemplate(
                category: "Servers",
                fields: [fieldReference, entryReference, futureReference]
            )
        ]

        let renamed = propagateFieldReferenceCategoryRename(
            templates: templates,
            from: "ACCOUNTS",
            to: "Identity"
        )
        #expect(renamed[0].fields[0].targetCategory == "Identity")
        #expect(renamed[0].fields[0].targetFieldId == fieldReference.targetFieldId)
        #expect(renamed[0].fields[1].targetCategory == " accounts ")
        #expect(renamed[0].fields[2].targetCategory == " accounts ")

        #expect(fieldReferenceTargetFieldIDs(
            targetCategory: " Accounts ",
            templates: templates
        ) == Set(["target-login"]))

        let source = makeFieldReferenceSourceEntry(fields: [
            CustomField(
                templateFieldId: fieldReference.id,
                name: fieldReference.name,
                value: "target-entry"
            ),
            CustomField(
                templateFieldId: entryReference.id,
                name: entryReference.name,
                value: "unmapped-entry"
            )
        ])
        let remapped = source
            .remappingEntryReferenceIDs(
                using: ["target-entry": "copied-target"],
                template: templates[0]
            )
            .remappingFieldReferenceIDs(
                using: ["target-entry": "copied-target"],
                template: templates[0]
            )
        #expect(remapped.customFields[0].value == "copied-target")
        #expect(remapped.customFields[1].value == "unmapped-entry")
    }

    @Test("Sync conflict copies preserve a resolvable field reference")
    func conflictCopyIsLossless() throws {
        let sourceField = makeFieldReferenceSourceField()
        let sourceTemplate = CategoryTemplate(category: "Servers", fields: [sourceField])
        let targetTemplate = CategoryTemplate(
            category: "Accounts",
            fields: [makeFieldReferenceTargetField()]
        )
        var local = makeFieldReferenceSourceEntry()
        local.label = "Local server"
        local.version = ["local": 2]
        local.updatedBy = "local"
        var remote = makeFieldReferenceSourceEntry()
        remote.label = "Remote server"
        remote.version = ["remote": 2]
        remote.updatedBy = "remote"

        let result = VaultSyncMerger(
            idGenerator: { "conflict-copy" },
            conflictStrategy: .localWins
        ).merge(localEntries: [local], remoteEntries: [remote])
        let copy = try #require(result.entries.first { $0.id == "conflict-copy" })

        #expect(copy.customFields.first?.templateFieldId == sourceField.id)
        #expect(copy.customFields.first?.value == "target-entry")
        #expect(sourceField.valueType == "fieldReference")
        #expect(sourceField.targetCategory == "Accounts")
        #expect(sourceField.targetFieldId == "target-login")
        #expect(resolveFieldReference(
            sourceEntry: copy,
            field: try #require(copy.customFields.first),
            categoryTemplates: [sourceTemplate, targetTemplate],
            entries: [copy, makeFieldReferenceTargetEntry()]
        )?.status == .resolved)
    }

    @MainActor
    @Test("Store copy import, search, rename, and template dependency guard are integrated")
    func storeIntegration() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PasswordManagerMacOSFieldReferenceP8-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = FileVaultRepository(baseDirectory: directory)
        let store = VaultStore(repository: repository, syncSettingsRepository: nil)
        #expect(store.setupMasterPassword("test-password", confirmation: "test-password"))

        let sourceField = makeFieldReferenceSourceField()
        let targetField = makeFieldReferenceTargetField()
        let export = ScopedVaultExport(
            scope: .category,
            exportedAt: Date(timeIntervalSince1970: 1_775_000_008),
            item: nil,
            category: "Servers",
            items: [makeFieldReferenceTargetEntry(), makeFieldReferenceSourceEntry()],
            categoryTemplates: [
                CategoryTemplate(category: "Accounts", fields: [targetField]),
                CategoryTemplate(category: "Servers", fields: [sourceField])
            ]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let fileName = "field-reference-p8.json"
        try encoder.encode(export).write(
            to: try repository.importsDirectoryURL.appendingPathComponent(fileName)
        )

        store.importScopedExport(fileName: fileName, strategy: .keepCopy)

        let importedTarget = try #require(store.entries.first { $0.label == "Payroll Account" })
        let importedSource = try #require(store.entries.first { $0.label == "Payroll Server" })
        #expect(importedTarget.id != "target-entry")
        #expect(importedSource.customFields.first?.value == importedTarget.id)
        #expect(store.categoryTemplateReferencedTargetFieldIDs(" accounts ") == Set([targetField.id]))

        for query in [importedTarget.label, "Accounts", targetField.name] {
            #expect(store.filteredEntries(searchText: query, filter: .all).contains {
                $0.id == importedSource.id
            })
        }
        for forbidden in [
            "private-target-value",
            importedTarget.id,
            targetField.id,
            "target-password-secret"
        ] {
            #expect(!store.filteredEntries(searchText: forbidden, filter: .all).contains {
                $0.id == importedSource.id
            })
        }

        let before = try #require(store.categoryTemplates.first {
            $0.category.caseInsensitiveCompare("Accounts") == .orderedSame
        })
        #expect(!store.updateCategoryTemplate("Accounts", fields: []))
        #expect(store.categoryTemplates.first {
            $0.category.caseInsensitiveCompare("Accounts") == .orderedSame
        } == before)
        #expect(store.statusMessage?.contains("Referenced field cannot be removed or retyped") == true)

        var retyped = targetField
        retyped.valueType = "entryReference"
        #expect(!store.updateCategoryTemplate("Accounts", fields: [retyped]))
        #expect(store.categoryTemplates.first {
            $0.category.caseInsensitiveCompare("Accounts") == .orderedSame
        } == before)

        var renamed = targetField
        renamed.name = "Login name"
        #expect(store.updateCategoryTemplate("Accounts", fields: [renamed]))
        #expect(store.categoryTemplates.first {
            $0.category.caseInsensitiveCompare("Accounts") == .orderedSame
        }?.fields.first { $0.id == targetField.id }?.name == "Login name")

        #expect(store.renameCategory("ACCOUNTS", to: "Identity"))
        #expect(store.categoryTemplates.first {
            $0.category.caseInsensitiveCompare("Servers") == .orderedSame
        }?.fields.first { $0.id == sourceField.id }?.targetCategory == "Identity")
        #expect(store.categoryTemplates.first {
            $0.category.caseInsensitiveCompare("Servers") == .orderedSame
        }?.fields.first { $0.id == sourceField.id }?.targetFieldId == targetField.id)
    }
}

private struct FieldReferenceScenario {
    var sourceCategory = "Servers"
    var sourceField = makeFieldReferenceSourceField()
    var sourceValue = "target-entry"
    var targetField = makeFieldReferenceTargetField()
    var targetEntry: VaultEntry? = makeFieldReferenceTargetEntry()
    var includeTargetTemplate = true

    func resolution() -> FieldReferenceResolution? {
        let sourceEntry = makeFieldReferenceSourceEntry(
            category: sourceCategory,
            fields: [
                CustomField(
                    templateFieldId: sourceField.id,
                    name: sourceField.name,
                    value: sourceValue
                )
            ]
        )
        var templates = [CategoryTemplate(category: sourceCategory, fields: [sourceField])]
        if includeTargetTemplate {
            templates.append(CategoryTemplate(category: "Accounts", fields: [targetField]))
        }
        return resolveFieldReference(
            sourceEntry: sourceEntry,
            field: sourceEntry.customFields[0],
            categoryTemplates: templates,
            entries: [sourceEntry] + (targetEntry.map { [$0] } ?? [])
        )
    }
}

private func makeFieldReferenceSourceField(
    targetCategory: String = "Accounts"
) -> FieldTemplate {
    FieldTemplate(
        id: "source-account-login",
        name: "Linked login",
        valueType: "fieldReference",
        targetCategory: targetCategory,
        targetFieldId: "target-login"
    )
}

private func makeFieldReferenceTargetField() -> FieldTemplate {
    FieldTemplate(id: "target-login", name: "Login alias")
}

private func makeFieldReferenceSourceEntry(
    category: String = "Servers",
    fields: [CustomField]? = nil
) -> VaultEntry {
    let sourceField = makeFieldReferenceSourceField()
    return VaultEntry(
        id: "source-entry",
        label: "Payroll Server",
        type: .server,
        payload: .server(ServerPayload(category: category)),
        customFields: fields ?? [
            CustomField(
                id: "source-value",
                templateFieldId: sourceField.id,
                name: sourceField.name,
                value: "target-entry"
            )
        ]
    )
}

private func makeFieldReferenceTargetEntry(
    category: String = "Accounts",
    customFields: [CustomField]? = nil,
    isDeleted: Bool = false
) -> VaultEntry {
    let targetField = makeFieldReferenceTargetField()
    return VaultEntry(
        id: "target-entry",
        label: "Payroll Account",
        type: .credential,
        payload: .credential(CredentialPayload(
            password: "target-password-secret",
            category: category
        )),
        customFields: customFields ?? [
            CustomField(
                id: "target-value",
                templateFieldId: targetField.id,
                name: targetField.name,
                value: "private-target-value"
            )
        ],
        isDeleted: isDeleted
    )
}
