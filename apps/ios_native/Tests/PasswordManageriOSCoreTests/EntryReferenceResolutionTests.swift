import Testing
@testable import PasswordManageriOSCore

@Suite("Entry reference resolution")
struct EntryReferenceResolutionTests {
    @Test("Exact target ID resolves to a safe display projection")
    func exactTargetIDResolvesToSafeDisplayProjection() throws {
        let target = targetEntry(
            id: "account-b",
            label: "Shared account",
            category: "Accounts",
            password: "must-not-be-projected"
        )
        let sameLabel = targetEntry(
            id: "account-a",
            label: target.label,
            category: "Accounts"
        )

        let resolution = try #require(resolveEntryReference(
            field: referenceField(value: target.id),
            template: referenceTemplate(targetCategory: "Accounts"),
            entries: [sameLabel, target]
        ))

        #expect(resolution == EntryReferenceResolution(
            status: .resolved,
            target: EntryReferenceTarget(
                id: "account-b",
                label: "Shared account",
                category: "Accounts"
            )
        ))
        let projection = try #require(resolution.target)
        #expect(Mirror(reflecting: projection).children.compactMap(\.label) == ["id", "label", "category"])
        let reflectedResolution = String(reflecting: resolution)
        #expect(!reflectedResolution.contains("must-not-be-projected"))
        #expect(!reflectedResolution.contains("private-token"))
        #expect(!reflectedResolution.contains("private-secret-key"))
    }

    @Test("Empty value wins before target lookup")
    func emptyValueWinsBeforeTargetLookup() throws {
        let resolution = try #require(resolveEntryReference(
            field: referenceField(value: "   \n"),
            template: referenceTemplate(targetCategory: "Accounts"),
            entries: [targetEntry(id: "   \n", category: "Other", isDeleted: true)]
        ))

        #expect(resolution == EntryReferenceResolution(status: .empty))
    }

    @Test("Missing target uses case-sensitive exact ID matching")
    func missingTargetUsesCaseSensitiveExactIDMatching() throws {
        let resolution = try #require(resolveEntryReference(
            field: referenceField(value: "Target-ID"),
            template: referenceTemplate(targetCategory: "Accounts"),
            entries: [targetEntry(id: "target-id", category: "Accounts")]
        ))

        #expect(resolution == EntryReferenceResolution(status: .missing))
    }

    @Test("Deleted target wins before category mismatch")
    func deletedTargetWinsBeforeCategoryMismatch() throws {
        let target = targetEntry(id: "deleted-account", category: "Archive", isDeleted: true)

        let resolution = try #require(resolveEntryReference(
            field: referenceField(value: target.id),
            template: referenceTemplate(targetCategory: "Accounts"),
            entries: [target]
        ))

        #expect(resolution.status == .deleted)
        #expect(resolution.target?.id == target.id)
        #expect(resolution.target?.category == "Archive")
    }

    @Test("Active target outside the configured category is a mismatch")
    func activeTargetOutsideConfiguredCategoryIsMismatch() throws {
        let target = targetEntry(id: "server-id", category: "Servers")

        let resolution = try #require(resolveEntryReference(
            field: referenceField(value: target.id),
            template: referenceTemplate(targetCategory: "Accounts"),
            entries: [target]
        ))

        #expect(resolution.status == .categoryMismatch)
        #expect(resolution.target?.id == target.id)
    }

    @Test("Target category comparison trims whitespace and ignores case")
    func targetCategoryComparisonTrimsWhitespaceAndIgnoresCase() throws {
        let target = targetEntry(id: "account-id", category: " Accounts ")

        let resolution = try #require(resolveEntryReference(
            field: referenceField(value: target.id),
            template: referenceTemplate(targetCategory: " accounts \n"),
            entries: [target]
        ))

        #expect(resolution.status == .resolved)
        #expect(resolution.target?.category == "Accounts")
    }

    @Test("Blank target category does not restrict the target")
    func blankTargetCategoryDoesNotRestrictTarget() throws {
        let target = targetEntry(id: "server-id", category: "Servers")

        let resolution = try #require(resolveEntryReference(
            field: referenceField(value: target.id),
            template: referenceTemplate(targetCategory: "  \n"),
            entries: [target]
        ))

        #expect(resolution.status == .resolved)
        #expect(resolution.target?.category == "Servers")
    }

    @Test("Only matching entry-reference template fields are resolved")
    func onlyMatchingEntryReferenceTemplateFieldsAreResolved() throws {
        let target = targetEntry(id: "account-id", category: "Accounts")
        let textTemplate = CategoryTemplate(
            category: "Servers",
            fields: [FieldTemplate(id: "template-owner", name: "Owner")]
        )

        #expect(resolveEntryReference(
            field: referenceField(value: target.id),
            template: textTemplate,
            entries: [target]
        ) == nil)
        #expect(resolveEntryReference(
            field: CustomField(
                id: "owner-field",
                templateFieldId: "missing-template-id",
                name: "Owner",
                value: target.id
            ),
            template: referenceTemplate(targetCategory: "Accounts"),
            entries: [target]
        ) == nil)

        let legacyResolution = try #require(resolveEntryReference(
            field: CustomField(
                id: "owner-field",
                templateFieldId: "",
                name: " owner ",
                value: target.id
            ),
            template: referenceTemplate(targetCategory: "Accounts"),
            entries: [target]
        ))
        #expect(legacyResolution.status == .resolved)

        #expect(resolveEntryReference(
            field: CustomField(
                id: "owner-field",
                templateFieldId: "   ",
                name: "Owner",
                value: target.id
            ),
            template: referenceTemplate(targetCategory: "Accounts"),
            entries: [target]
        ) == nil)
    }

    @Test("Category rename only updates matching entry-reference targets")
    func categoryRenameOnlyUpdatesMatchingEntryReferenceTargets() throws {
        let reference = FieldTemplate(
            id: "template-owner",
            name: "Owner",
            valueType: "entryReference",
            targetCategory: " Accounts "
        )
        let text = FieldTemplate(
            id: "template-text",
            name: "Text",
            valueType: "text",
            targetCategory: "accounts"
        )
        let unknown = FieldTemplate(
            id: "template-future",
            name: "Future",
            valueType: "futureReference",
            targetCategory: "ACCOUNTS"
        )
        let templates = [
            CategoryTemplate(category: "Servers", fields: [reference, text, unknown]),
            CategoryTemplate(
                category: "Services",
                fields: [FieldTemplate(
                    id: "template-service-owner",
                    name: "Service Owner",
                    valueType: "entryReference",
                    targetCategory: "accounts"
                )]
            )
        ]

        let renamed = propagateEntryReferenceCategoryRename(
            templates: templates,
            from: " accounts\n",
            to: " Identity "
        )

        #expect(renamed[0].fields[0] == FieldTemplate(
            id: reference.id,
            name: reference.name,
            valueType: reference.valueType,
            targetCategory: "Identity"
        ))
        #expect(renamed[0].fields[1] == text)
        #expect(renamed[0].fields[2] == unknown)
        #expect(renamed[1].fields[0].targetCategory == "Identity")
    }

    @Test("Target lifecycle preserves the reference value and changes only resolution state")
    func targetLifecyclePreservesReferenceValueAndChangesResolutionState() throws {
        let field = referenceField(value: "target-id")
        let template = referenceTemplate(targetCategory: "Accounts")
        var target = targetEntry(id: field.value, category: "Accounts")

        #expect(resolveEntryReference(field: field, template: template, entries: [target])?.status == .resolved)

        target.isDeleted = true
        #expect(field.value == "target-id")
        #expect(resolveEntryReference(field: field, template: template, entries: [target])?.status == .deleted)

        target.isDeleted = false
        #expect(field.value == "target-id")
        #expect(resolveEntryReference(field: field, template: template, entries: [target])?.status == .resolved)

        target.payload = .credential(CredentialPayload(category: "Archive"))
        #expect(field.value == "target-id")
        #expect(
            resolveEntryReference(field: field, template: template, entries: [target])?.status ==
                .categoryMismatch
        )
    }

    private func referenceTemplate(targetCategory: String) -> CategoryTemplate {
        CategoryTemplate(
            category: "Servers",
            fields: [
                FieldTemplate(
                    id: "template-owner",
                    name: "Owner",
                    valueType: "entryReference",
                    targetCategory: targetCategory
                )
            ]
        )
    }

    private func referenceField(value: String) -> CustomField {
        CustomField(
            id: "owner-field",
            templateFieldId: "template-owner",
            name: "Owner",
            value: value
        )
    }

    private func targetEntry(
        id: String,
        label: String = "Target",
        category: String,
        password: String = "private-password",
        isDeleted: Bool = false
    ) -> VaultEntry {
        VaultEntry(
            id: id,
            label: label,
            type: .credential,
            payload: .credential(CredentialPayload(
                username: "private-user",
                password: password,
                token: "private-token",
                secretKey: "private-secret-key",
                category: category
            )),
            isDeleted: isDeleted
        )
    }
}
