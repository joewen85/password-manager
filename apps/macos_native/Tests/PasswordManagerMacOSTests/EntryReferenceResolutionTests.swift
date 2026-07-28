import Testing
@testable import PasswordManagerMacOSApp

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
