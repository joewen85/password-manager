#include "../src/vault_core.hpp"

#include <algorithm>
#include <cassert>
#include <cstdio>
#include <fstream>
#include <iostream>
#include <sstream>
#include <stdexcept>
#include <vector>

namespace {

std::string readContractFixture(const std::string& name) {
    const std::vector<std::string> candidates = {
        "fixtures/vault-contract/v1/" + name,
        "../../fixtures/vault-contract/v1/" + name,
    };
    for (const auto& path : candidates) {
        std::ifstream input(path);
        if (!input) continue;
        std::ostringstream contents;
        contents << input.rdbuf();
        return contents.str();
    }
    throw std::runtime_error("Unable to locate vault contract fixture: " + name);
}

} // namespace

int main() {
    pm::VaultSnapshot snapshot;
    auto entry = pm::makeEntry("Production Email", "credential", "admin@example.com", "secret-password");
    entry.category = "Work";
    entry.tags = {"mail", "shared"};
    entry.notes = "owner:sre-team";
    entry.customFields = {pm::CustomField{
        "11111111-1111-4111-8111-111111111111",
        "Owner",
        "SRE",
        "template_owner",
    }};
    snapshot.entries.push_back(entry);

    auto envelope = pm::createEnvelope("test-password", snapshot);
    assert(envelope.masterKeyRecord.iterations == pm::kDefaultIterations);
    assert(!envelope.encryptedVault.ciphertextBase64.empty());
    auto loaded = pm::decryptEnvelope("test-password", envelope);
    assert(loaded.syncStatus == "Loaded");
    assert(loaded.entries.size() == 1);
    assert(loaded.entries[0].label == "Production Email");
    assert(loaded.entries[0].category == "Work");
    assert(loaded.entries[0].tags.size() == 2);
    assert(loaded.entries[0].notes == "owner:sre-team");
    assert(loaded.entries[0].customFields.size() == 1);
    assert(loaded.entries[0].customFields[0].name == "Owner");
    assert(loaded.entries[0].customFields[0].templateFieldId == "template_owner");
    bool rejected = false;
    try {
        (void)pm::decryptEnvelope("wrong-password", envelope);
    } catch (const std::exception&) {
        rejected = true;
    }
    assert(rejected);

    assert(pm::generateTotp("GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ", 59) == "287082");
    assert(pm::verifyTotp("GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ", "287082", 59));
    assert(!pm::verifyTotp("GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ", "000000", 59));

    auto active = pm::filterEntries(snapshot.entries, "Production", "all");
    assert(active.size() == 1);
    entry.notes = "ip:1.2.3.4 owner:sre-team https://ops.example.com";
    snapshot.entries[0] = entry;
    assert(pm::filterEntries(snapshot.entries, "name:Production", "all").size() == 1);
    assert(pm::filterEntries(snapshot.entries, "ip:1.2.3.4", "all").size() == 1);
    assert(pm::filterEntries(snapshot.entries, "owner:sre-team", "all").size() == 1);
    assert(pm::filterEntries(snapshot.entries, "https://ops.example.com", "all").size() == 1);
    assert(pm::filterEntries(snapshot.entries, "tag:mail ip:1.2.3.4", "all").size() == 1);
    assert(pm::filterEntries(snapshot.entries, "ip:9.9.9.9", "all").empty());
    assert(pm::rebuildCategories(snapshot.entries).front() == "Work");
    assert(pm::rebuildTags(snapshot.entries).size() == 2);

    pm::VaultEntry local = entry;
    local.id = "shared";
    local.label = "Local";
    local.version = {{"linux", 2}, {"remote", 1}};
    local.updatedBy = "linux";
    pm::VaultEntry remote = entry;
    remote.id = "shared";
    remote.label = "Remote";
    local.customFields = {pm::CustomField{"owner-local", "Owner", "account-a", "template_owner"}};
    remote.customFields = {pm::CustomField{"owner-remote", "Owner", "account-b", "template_owner"}};
    remote.version = {{"linux", 1}, {"remote", 2}};
    remote.updatedBy = "remote";
    assert(pm::compareVersion(local.version, remote.version) == "concurrent");
    auto merged = pm::mergeEntries({local}, {remote}, "localWins");
    assert(merged.stats.conflicts == 1);
    assert(merged.entries.size() == 2);
    assert(merged.entries[1].label.find("Remote") != std::string::npos);
    assert(merged.entries[0].customFields[0].value == "account-a");
    assert(merged.entries[1].customFields[0].value == "account-b");
    assert(merged.entries[0].customFields[0].templateFieldId == "template_owner");
    assert(merged.entries[1].customFields[0].templateFieldId == "template_owner");

    pm::VaultEntry androidEntry = entry;
    androidEntry.id = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa";
    androidEntry.label = "Android";
    androidEntry.version = {{"android", 2}, {"macos", 1}};
    androidEntry.updatedBy = "android";
    pm::VaultEntry swiftEntry = entry;
    swiftEntry.id = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA";
    swiftEntry.label = "Swift";
    swiftEntry.version = {{"android", 1}, {"macos", 1}};
    swiftEntry.updatedBy = "macos";
    auto canonicalMerged = pm::mergeEntries({androidEntry}, {swiftEntry}, "localWins");
    assert(canonicalMerged.stats.conflicts == 0);
    assert(canonicalMerged.entries.size() == 1);
    assert(canonicalMerged.entries[0].id == "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa");
    assert(canonicalMerged.entries[0].label == "Android");

    pm::VaultSnapshot uppercaseSnapshot;
    uppercaseSnapshot.entries.push_back(swiftEntry);
    const auto serialized = pm::serializeSnapshotJson(uppercaseSnapshot);
    assert(serialized.find("AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA") == std::string::npos);
    assert(serialized.find("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa") != std::string::npos);
    assert(serialized.find("\"payload\":{\"credential\"") != std::string::npos);
    assert(serialized.find("\"customFields\"") != std::string::npos);
    assert(serialized.find("\"updatedBy\"") != std::string::npos);

    const auto parsedEntrySnapshot = pm::parseSnapshotJson(serialized);
    assert(parsedEntrySnapshot.entries.size() == 1);
    assert(parsedEntrySnapshot.entries[0].id == "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa");
    assert(parsedEntrySnapshot.entries[0].tags.size() == 2);
    assert(parsedEntrySnapshot.entries[0].customFields.size() == 1);
    assert(parsedEntrySnapshot.entries[0].version.at("macos") == 1);

    pm::VaultSnapshot opaqueIdSnapshot;
    auto opaqueIdEntry = pm::makeEntry("Opaque", "credential", "", "");
    opaqueIdEntry.id = "Opaque-MixedCase-ID";
    opaqueIdEntry.customFields = {pm::CustomField{"Custom-MixedCase-ID", "Owner", "", "Template-MixedCase-ID"}};
    opaqueIdSnapshot.entries.push_back(opaqueIdEntry);
    const auto opaqueIdJson = pm::serializeSnapshotJson(opaqueIdSnapshot);
    const auto opaqueIdRoundTrip = pm::parseSnapshotJson(opaqueIdJson);
    assert(opaqueIdRoundTrip.entries[0].id == "Opaque-MixedCase-ID");
    assert(opaqueIdRoundTrip.entries[0].customFields[0].id == "Custom-MixedCase-ID");
    assert(opaqueIdRoundTrip.entries[0].customFields[0].templateFieldId == "Template-MixedCase-ID");

    pm::VaultSnapshot serviceSnapshot;
    auto serviceEntry = pm::makeEntry("Billing API", "service", "svc-user", "svc-secret");
    serviceEntry.category = "Services";
    serviceSnapshot.entries.push_back(serviceEntry);
    const auto parsedServiceSnapshot = pm::parseSnapshotJson(pm::serializeSnapshotJson(serviceSnapshot));
    assert(parsedServiceSnapshot.entries.size() == 1);
    assert(parsedServiceSnapshot.entries[0].type == "service");
    assert(parsedServiceSnapshot.entries[0].username == "svc-user");
    assert(parsedServiceSnapshot.entries[0].secret == "svc-secret");
    serviceSnapshot.updatedAt = "2026-06-28T00:00:00Z";
    const auto parsedTimestampSnapshot = pm::parseSnapshotJson(pm::serializeSnapshotJson(serviceSnapshot));
    assert(parsedTimestampSnapshot.updatedAt == "2026-06-28T00:00:00Z");

    pm::VaultSnapshot categorySnapshot;
    assert(pm::addCategory(categorySnapshot, "Infra", pm::CategoryTypePreset::Server, {"Owner", "备注", ""}));
    assert(!pm::addCategory(categorySnapshot, "infra"));
    assert(categorySnapshot.categories.size() == 1);
    assert(categorySnapshot.categoryTemplates.size() == 1);
    assert(categorySnapshot.categoryTemplates[0].fields.size() == 6);
    assert(categorySnapshot.categoryTemplates[0].fields[0].name == "名称");
    assert(categorySnapshot.categoryTemplates[0].fields[1].name == "备注");
    assert(categorySnapshot.categoryTemplates[0].fields[5].name == "Owner");
    const auto categoryJson = pm::serializeSnapshotJson(categorySnapshot);
    assert(categoryJson.find("\"categoryTemplates\"") != std::string::npos);
    assert(categoryJson.find("\"category\":\"Infra\"") != std::string::npos);
    assert(categoryJson.find("\"name\":\"Owner\"") != std::string::npos);

    pm::VaultSnapshot customCategorySnapshot;
    assert(pm::addCategory(customCategorySnapshot, "Private", pm::categoryFieldsWithCustom({"Owner", "备注", ""})));
    assert(customCategorySnapshot.categoryTemplates.size() == 1);
    assert(customCategorySnapshot.categoryTemplates[0].fields.size() == 3);
    assert(customCategorySnapshot.categoryTemplates[0].fields[0].name == "名称");
    assert(customCategorySnapshot.categoryTemplates[0].fields[1].name == "备注");
    assert(customCategorySnapshot.categoryTemplates[0].fields[2].name == "Owner");

    pm::VaultSnapshot shortcutOnlyCategorySnapshot;
    assert(pm::addCategory(shortcutOnlyCategorySnapshot, "Ops", pm::categoryFieldsWithCustom({"IP地址", "端口", "Owner", "ip地址", ""})));
    assert(shortcutOnlyCategorySnapshot.categoryTemplates.size() == 1);
    assert(shortcutOnlyCategorySnapshot.categoryTemplates[0].fields.size() == 5);
    assert(shortcutOnlyCategorySnapshot.categoryTemplates[0].fields[0].name == "名称");
    assert(shortcutOnlyCategorySnapshot.categoryTemplates[0].fields[1].name == "备注");
    assert(shortcutOnlyCategorySnapshot.categoryTemplates[0].fields[2].name == "IP地址");
    assert(shortcutOnlyCategorySnapshot.categoryTemplates[0].fields[3].name == "端口");
    assert(shortcutOnlyCategorySnapshot.categoryTemplates[0].fields[4].name == "Owner");

    const auto parsedCategorySnapshot = pm::parseSnapshotJson(pm::serializeSnapshotJson(categorySnapshot));
    assert(parsedCategorySnapshot.categories == categorySnapshot.categories);
    assert(parsedCategorySnapshot.categoryTemplates.size() == 1);
    assert(parsedCategorySnapshot.categoryTemplates[0].fields[5].name == "Owner");
    assert(parsedCategorySnapshot.categoryTemplates[0].fields[0].id == "template_名称");
    assert(parsedCategorySnapshot.categoryTemplates[0].fields[0].valueType == "text");

    const auto categoryStateFixture = pm::parseSnapshotJson(R"json({
        "entries":[],
        "categories":[],
        "categoryTemplates":[],
        "categoryStates":[{
            "name":"test",
            "isDeleted":true,
            "updatedAt":"2026-06-28T00:06:00Z",
            "version":{"macos":2},
            "updatedBy":"macos"
        }],
        "tags":[],
        "updatedAt":"2026-06-28T00:06:00Z"
    })json");
    const auto categoryStateJson = pm::serializeSnapshotJson(categoryStateFixture);
    assert(categoryStateJson.find("\"categoryStates\"") != std::string::npos);
    assert(categoryStateJson.find("\"name\":\"test\"") != std::string::npos);
    assert(categoryStateJson.find("\"isDeleted\":true") != std::string::npos);
    assert(categoryStateJson.find("\"macos\":2") != std::string::npos);

    const auto referenceFixture = pm::parseSnapshotJson(
        readContractFixture("snapshot-entry-reference.json")
    );
    assert(referenceFixture.entries.size() == 2);
    assert(referenceFixture.entries[0].id == "harmony_target_01");
    assert(referenceFixture.entries[1].customFields.size() == 2);
    assert(referenceFixture.entries[1].customFields[0].id == "harmony_field_01");
    assert(referenceFixture.entries[1].customFields[0].templateFieldId == "44444444-4444-4444-8444-444444444444");
    assert(referenceFixture.entries[1].customFields[0].value == "harmony_target_01");
    assert(referenceFixture.categoryTemplates[1].fields[0].valueType == "entryReference");
    assert(referenceFixture.categoryTemplates[1].fields[0].targetCategory == "Accounts");
    assert(referenceFixture.categoryTemplates[1].fields[0].targetFieldId.empty());
    const auto referenceRoundTrip = pm::parseSnapshotJson(pm::serializeSnapshotJson(referenceFixture));
    assert(referenceRoundTrip.entries[0].id == "harmony_target_01");
    assert(referenceRoundTrip.entries[1].customFields[0].templateFieldId == "44444444-4444-4444-8444-444444444444");
    assert(referenceRoundTrip.categoryTemplates[1].fields[0].valueType == "entryReference");

    const auto fieldReferenceFixture = pm::parseSnapshotJson(
        readContractFixture("snapshot-field-reference.json")
    );
    assert(fieldReferenceFixture.entries.size() == 2);
    assert(fieldReferenceFixture.categoryTemplates.size() == 2);
    const auto& sourceFieldTemplate = fieldReferenceFixture.categoryTemplates[1].fields[0];
    assert(sourceFieldTemplate.valueType == "fieldReference");
    assert(sourceFieldTemplate.targetCategory == "Accounts");
    assert(sourceFieldTemplate.targetFieldId == "target_email_field");
    assert(fieldReferenceFixture.entries[1].customFields[0].value == "account_target_01");
    const auto fieldReferenceRoundTrip = pm::parseSnapshotJson(
        pm::serializeSnapshotJson(fieldReferenceFixture)
    );
    assert(fieldReferenceRoundTrip.categoryTemplates[1].fields[0].valueType == "fieldReference");
    assert(fieldReferenceRoundTrip.categoryTemplates[1].fields[0].targetFieldId == "target_email_field");

    const auto& fieldReferenceTarget = fieldReferenceFixture.entries[0];
    const auto& fieldReferenceSource = fieldReferenceFixture.entries[1];
    const auto& fieldReferenceValue = fieldReferenceSource.customFields[0];
    const auto resolvedFieldReference = pm::resolveFieldReference(
        fieldReferenceSource,
        fieldReferenceValue,
        fieldReferenceFixture.categoryTemplates,
        fieldReferenceFixture.entries
    );
    assert(resolvedFieldReference.has_value());
    assert(resolvedFieldReference->status == pm::FieldReferenceStatus::Resolved);
    assert(resolvedFieldReference->target.has_value());
    assert(resolvedFieldReference->target->id == fieldReferenceTarget.id);
    assert(resolvedFieldReference->target->label == fieldReferenceTarget.label);
    assert(resolvedFieldReference->target->category == "Accounts");
    assert(resolvedFieldReference->target->fieldId == "target_email_field");
    assert(resolvedFieldReference->target->fieldName == "Email");
    assert(resolvedFieldReference->target->value == "ops@example.com");

    auto nameFieldReferenceTemplates = fieldReferenceFixture.categoryTemplates;
    nameFieldReferenceTemplates[0].fields = {
        pm::FieldTemplate{"template_名称", "名称", "text", "", ""},
    };
    nameFieldReferenceTemplates[1].fields[0].targetFieldId = "template_名称";
    auto nameFieldReferenceEntries = fieldReferenceFixture.entries;
    nameFieldReferenceEntries[0].customFields.clear();
    const auto nameFieldReference = pm::resolveFieldReference(
        nameFieldReferenceEntries[1],
        nameFieldReferenceEntries[1].customFields[0],
        nameFieldReferenceTemplates,
        nameFieldReferenceEntries
    );
    assert(nameFieldReference.has_value());
    assert(nameFieldReference->status == pm::FieldReferenceStatus::Resolved);
    assert(nameFieldReference->target.has_value());
    assert(nameFieldReference->target->fieldId == "template_名称");
    assert(nameFieldReference->target->fieldName == "名称");
    assert(nameFieldReference->target->value == fieldReferenceTarget.label);

    auto emptyFieldReferenceValue = fieldReferenceValue;
    emptyFieldReferenceValue.value = " \t\n";
    const auto emptyFieldReference = pm::resolveFieldReference(
        fieldReferenceSource,
        emptyFieldReferenceValue,
        fieldReferenceFixture.categoryTemplates,
        fieldReferenceFixture.entries
    );
    assert(emptyFieldReference.has_value());
    assert(emptyFieldReference->status == pm::FieldReferenceStatus::Empty);
    assert(!emptyFieldReference->target.has_value());

    auto invalidFieldReferenceTemplates = fieldReferenceFixture.categoryTemplates;
    invalidFieldReferenceTemplates[1].fields[0].targetFieldId.clear();
    const auto invalidFieldReference = pm::resolveFieldReference(
        fieldReferenceSource,
        fieldReferenceValue,
        invalidFieldReferenceTemplates,
        fieldReferenceFixture.entries
    );
    assert(invalidFieldReference.has_value());
    assert(invalidFieldReference->status == pm::FieldReferenceStatus::InvalidConfiguration);

    auto selfReferenceTemplates = fieldReferenceFixture.categoryTemplates;
    selfReferenceTemplates[1].fields[0].targetCategory = " Servers ";
    selfReferenceTemplates[1].fields[0].targetFieldId = selfReferenceTemplates[1].fields[0].id;
    const auto selfReference = pm::resolveFieldReference(
        fieldReferenceSource,
        fieldReferenceValue,
        selfReferenceTemplates,
        fieldReferenceFixture.entries
    );
    assert(selfReference.has_value());
    assert(selfReference->status == pm::FieldReferenceStatus::InvalidConfiguration);

    auto missingFieldReferenceValue = fieldReferenceValue;
    missingFieldReferenceValue.value = "missing_target_entry";
    const auto missingFieldReference = pm::resolveFieldReference(
        fieldReferenceSource,
        missingFieldReferenceValue,
        fieldReferenceFixture.categoryTemplates,
        fieldReferenceFixture.entries
    );
    assert(missingFieldReference.has_value());
    assert(missingFieldReference->status == pm::FieldReferenceStatus::Missing);

    auto deletedFieldReferenceEntries = fieldReferenceFixture.entries;
    deletedFieldReferenceEntries[0].isDeleted = true;
    const auto deletedFieldReference = pm::resolveFieldReference(
        deletedFieldReferenceEntries[1],
        deletedFieldReferenceEntries[1].customFields[0],
        fieldReferenceFixture.categoryTemplates,
        deletedFieldReferenceEntries
    );
    assert(deletedFieldReference.has_value());
    assert(deletedFieldReference->status == pm::FieldReferenceStatus::Deleted);
    assert(deletedFieldReference->target.has_value());
    assert(deletedFieldReference->target->value.empty());

    auto mismatchedFieldReferenceEntries = fieldReferenceFixture.entries;
    mismatchedFieldReferenceEntries[0].category = "Archive";
    const auto mismatchedFieldReference = pm::resolveFieldReference(
        mismatchedFieldReferenceEntries[1],
        mismatchedFieldReferenceEntries[1].customFields[0],
        fieldReferenceFixture.categoryTemplates,
        mismatchedFieldReferenceEntries
    );
    assert(mismatchedFieldReference.has_value());
    assert(mismatchedFieldReference->status == pm::FieldReferenceStatus::CategoryMismatch);

    auto missingTargetFieldTemplates = fieldReferenceFixture.categoryTemplates;
    missingTargetFieldTemplates[0].fields.clear();
    const auto missingTargetField = pm::resolveFieldReference(
        fieldReferenceSource,
        fieldReferenceValue,
        missingTargetFieldTemplates,
        fieldReferenceFixture.entries
    );
    assert(missingTargetField.has_value());
    assert(missingTargetField->status == pm::FieldReferenceStatus::TargetFieldMissing);

    auto unsupportedTargetFieldTemplates = fieldReferenceFixture.categoryTemplates;
    unsupportedTargetFieldTemplates[0].fields[0].valueType = "entryReference";
    const auto unsupportedTargetField = pm::resolveFieldReference(
        fieldReferenceSource,
        fieldReferenceValue,
        unsupportedTargetFieldTemplates,
        fieldReferenceFixture.entries
    );
    assert(unsupportedTargetField.has_value());
    assert(unsupportedTargetField->status == pm::FieldReferenceStatus::TargetFieldUnsupported);
    assert(unsupportedTargetField->target.has_value());
    assert(unsupportedTargetField->target->value.empty());

    auto emptyTargetFieldEntries = fieldReferenceFixture.entries;
    emptyTargetFieldEntries[0].customFields.clear();
    const auto absentTargetFieldValue = pm::resolveFieldReference(
        emptyTargetFieldEntries[1],
        emptyTargetFieldEntries[1].customFields[0],
        fieldReferenceFixture.categoryTemplates,
        emptyTargetFieldEntries
    );
    assert(absentTargetFieldValue.has_value());
    assert(absentTargetFieldValue->status == pm::FieldReferenceStatus::TargetFieldEmpty);
    emptyTargetFieldEntries[0].customFields.push_back(pm::CustomField{
        "blank_email_value",
        "Email",
        " \n",
        "target_email_field",
    });
    const auto blankTargetFieldValue = pm::resolveFieldReference(
        emptyTargetFieldEntries[1],
        emptyTargetFieldEntries[1].customFields[0],
        fieldReferenceFixture.categoryTemplates,
        emptyTargetFieldEntries
    );
    assert(blankTargetFieldValue.has_value());
    assert(blankTargetFieldValue->status == pm::FieldReferenceStatus::TargetFieldEmpty);

    auto legacyTargetFieldEntries = fieldReferenceFixture.entries;
    legacyTargetFieldEntries[0].customFields[0].templateFieldId.clear();
    const auto legacyTargetFieldValue = pm::resolveFieldReference(
        legacyTargetFieldEntries[1],
        legacyTargetFieldEntries[1].customFields[0],
        fieldReferenceFixture.categoryTemplates,
        legacyTargetFieldEntries
    );
    assert(legacyTargetFieldValue.has_value());
    assert(legacyTargetFieldValue->status == pm::FieldReferenceStatus::Resolved);
    assert(legacyTargetFieldValue->target.has_value());
    assert(legacyTargetFieldValue->target->value == "ops@example.com");

    auto exactTargetFieldPriorityEntries = fieldReferenceFixture.entries;
    auto legacyDuplicateTargetField = exactTargetFieldPriorityEntries[0].customFields[0];
    legacyDuplicateTargetField.id = "legacy_duplicate_email";
    legacyDuplicateTargetField.templateFieldId.clear();
    legacyDuplicateTargetField.name = " email ";
    legacyDuplicateTargetField.value = "legacy@example.com";
    exactTargetFieldPriorityEntries[0].customFields.insert(
        exactTargetFieldPriorityEntries[0].customFields.begin(),
        legacyDuplicateTargetField
    );
    const auto exactTargetFieldPriority = pm::resolveFieldReference(
        exactTargetFieldPriorityEntries[1],
        exactTargetFieldPriorityEntries[1].customFields[0],
        fieldReferenceFixture.categoryTemplates,
        exactTargetFieldPriorityEntries
    );
    assert(exactTargetFieldPriority.has_value());
    assert(exactTargetFieldPriority->status == pm::FieldReferenceStatus::Resolved);
    assert(exactTargetFieldPriority->target.has_value());
    assert(exactTargetFieldPriority->target->value == "ops@example.com");

    auto mismatchedTargetValueIdEntries = fieldReferenceFixture.entries;
    mismatchedTargetValueIdEntries[0].customFields[0].templateFieldId = "TARGET_EMAIL_FIELD";
    const auto mismatchedTargetValueId = pm::resolveFieldReference(
        mismatchedTargetValueIdEntries[1],
        mismatchedTargetValueIdEntries[1].customFields[0],
        fieldReferenceFixture.categoryTemplates,
        mismatchedTargetValueIdEntries
    );
    assert(mismatchedTargetValueId.has_value());
    assert(mismatchedTargetValueId->status == pm::FieldReferenceStatus::TargetFieldEmpty);

    auto renamedTargetFieldTemplates = fieldReferenceFixture.categoryTemplates;
    renamedTargetFieldTemplates[0].fields[0].name = "Directory Address";
    renamedTargetFieldTemplates[1].fields[0].name = "Linked Account";
    const auto renamedTargetField = pm::resolveFieldReference(
        fieldReferenceSource,
        fieldReferenceValue,
        renamedTargetFieldTemplates,
        fieldReferenceFixture.entries
    );
    assert(renamedTargetField.has_value());
    assert(renamedTargetField->status == pm::FieldReferenceStatus::Resolved);
    assert(renamedTargetField->target->fieldName == "Directory Address");
    assert(renamedTargetField->target->value == "ops@example.com");

    auto wrongTargetFieldIdTemplates = renamedTargetFieldTemplates;
    wrongTargetFieldIdTemplates[1].fields[0].targetFieldId = "TARGET_EMAIL_FIELD";
    const auto wrongTargetFieldId = pm::resolveFieldReference(
        fieldReferenceSource,
        fieldReferenceValue,
        wrongTargetFieldIdTemplates,
        fieldReferenceFixture.entries
    );
    assert(wrongTargetFieldId.has_value());
    assert(wrongTargetFieldId->status == pm::FieldReferenceStatus::TargetFieldMissing);

    assert(pm::isTargetFieldReferenced(
        fieldReferenceFixture.categoryTemplates,
        " accounts ",
        "target_email_field"
    ));
    assert(!pm::isTargetFieldReferenced(
        fieldReferenceFixture.categoryTemplates,
        "Accounts",
        "TARGET_EMAIL_FIELD"
    ));

    const auto renamedFieldReferenceTemplates = pm::propagateEntryReferenceCategoryRename(
        fieldReferenceFixture.categoryTemplates,
        " accounts ",
        "Identity"
    );
    assert(renamedFieldReferenceTemplates[1].fields[0].targetCategory == "Identity");
    assert(renamedFieldReferenceTemplates[1].fields[0].targetFieldId == "target_email_field");

    const auto remappedFieldReferenceValues = pm::remapEntryReferenceIds(
        fieldReferenceSource.customFields,
        fieldReferenceFixture.categoryTemplates[1].fields,
        {{"account_target_01", "copied_account_target"}}
    );
    assert(remappedFieldReferenceValues[0].value == "copied_account_target");
    assert(remappedFieldReferenceValues[0].templateFieldId == "source_owner_email_field");

    const auto fieldReferenceSearchProjection = pm::projectCustomFieldsForSearch(
        fieldReferenceSource,
        renamedTargetFieldTemplates,
        fieldReferenceFixture.entries
    );
    assert(fieldReferenceSearchProjection[0].value == "Production Account Accounts Directory Address");
    for (const auto& forbidden : {
        std::string("ops@example.com"),
        std::string("account_target_01"),
        std::string("fixture-password"),
    }) {
        assert(fieldReferenceSearchProjection[0].value.find(forbidden) == std::string::npos);
        const auto matches = pm::filterEntries(
            fieldReferenceFixture.entries,
            renamedTargetFieldTemplates,
            forbidden,
            "all"
        );
        assert(std::none_of(matches.begin(), matches.end(), [&](const pm::VaultEntry& candidate) {
            return candidate.id == fieldReferenceSource.id;
        }));
    }
    const auto targetFieldNameMatches = pm::filterEntries(
        fieldReferenceFixture.entries,
        renamedTargetFieldTemplates,
        "Directory Address",
        "all"
    );
    assert(std::any_of(targetFieldNameMatches.begin(), targetFieldNameMatches.end(), [&](const pm::VaultEntry& candidate) {
        return candidate.id == fieldReferenceSource.id;
    }));

    const auto referenceSearchByLabel = pm::filterEntries(
        referenceFixture.entries,
        referenceFixture.categoryTemplates,
        "Production Account",
        "all"
    );
    assert(std::any_of(referenceSearchByLabel.begin(), referenceSearchByLabel.end(), [](const pm::VaultEntry& candidate) {
        return candidate.id == "22222222-2222-4222-8222-222222222222";
    }));
    const auto referenceSearchByCategory = pm::filterEntries(
        referenceFixture.entries,
        referenceFixture.categoryTemplates,
        "owner:Accounts",
        "all"
    );
    assert(std::any_of(referenceSearchByCategory.begin(), referenceSearchByCategory.end(), [](const pm::VaultEntry& candidate) {
        return candidate.id == "22222222-2222-4222-8222-222222222222";
    }));
    assert(pm::filterEntries(
        referenceFixture.entries,
        referenceFixture.categoryTemplates,
        "harmony_target_01",
        "all"
    ).empty());
    const auto targetSecretSearch = pm::filterEntries(
        referenceFixture.entries,
        referenceFixture.categoryTemplates,
        "secret:fixture-password",
        "all"
    );
    assert(std::none_of(targetSecretSearch.begin(), targetSecretSearch.end(), [](const pm::VaultEntry& candidate) {
        return candidate.id == "22222222-2222-4222-8222-222222222222";
    }));
    auto mismatchedSearchEntries = referenceFixture.entries;
    mismatchedSearchEntries[0].category = "Archive";
    const auto mismatchedTargetSearch = pm::filterEntries(
        mismatchedSearchEntries,
        referenceFixture.categoryTemplates,
        "Production Account",
        "all"
    );
    assert(std::none_of(mismatchedTargetSearch.begin(), mismatchedTargetSearch.end(), [](const pm::VaultEntry& candidate) {
        return candidate.id == "22222222-2222-4222-8222-222222222222";
    }));

    const auto remappedReferenceFields = pm::remapEntryReferenceIds(
        referenceFixture.entries[1].customFields,
        referenceFixture.categoryTemplates[1].fields,
        {{"harmony_target_01", "copied-target-id"}}
    );
    assert(remappedReferenceFields[0].value == "copied-target-id");
    assert(remappedReferenceFields[0].templateFieldId == referenceFixture.entries[1].customFields[0].templateFieldId);
    assert(remappedReferenceFields[1].value.empty());
    const auto unresolvedReferenceFields = pm::remapEntryReferenceIds(
        referenceFixture.entries[1].customFields,
        referenceFixture.categoryTemplates[1].fields,
        {}
    );
    assert(unresolvedReferenceFields[0].value == "harmony_target_01");

    const auto& referenceTarget = referenceFixture.entries[0];
    auto referenceField = referenceFixture.entries[1].customFields[0];
    auto referenceTemplateFields = referenceFixture.categoryTemplates[1].fields;
    referenceTemplateFields[0].targetCategory = " accounts ";
    const auto resolvedReference = pm::resolveEntryReference(
        referenceField,
        referenceTemplateFields,
        referenceFixture.entries
    );
    assert(resolvedReference.has_value());
    assert(resolvedReference->status == pm::EntryReferenceStatus::Resolved);
    assert(resolvedReference->target.has_value());
    assert(resolvedReference->target->id == referenceTarget.id);
    assert(resolvedReference->target->label == referenceTarget.label);
    assert(resolvedReference->target->category == referenceTarget.category);

    referenceField.value = " \t\n";
    const auto emptyReference = pm::resolveEntryReference(referenceField, referenceTemplateFields, referenceFixture.entries);
    assert(emptyReference.has_value());
    assert(emptyReference->status == pm::EntryReferenceStatus::Empty);
    assert(!emptyReference->target.has_value());

    referenceField.value = "missing_target";
    const auto missingReference = pm::resolveEntryReference(referenceField, referenceTemplateFields, referenceFixture.entries);
    assert(missingReference.has_value());
    assert(missingReference->status == pm::EntryReferenceStatus::Missing);
    assert(!missingReference->target.has_value());

    referenceField.value = "HARMONY_TARGET_01";
    const auto caseChangedId = pm::resolveEntryReference(referenceField, referenceTemplateFields, referenceFixture.entries);
    assert(caseChangedId.has_value());
    assert(caseChangedId->status == pm::EntryReferenceStatus::Missing);

    auto deletedEntries = referenceFixture.entries;
    deletedEntries[0].isDeleted = true;
    deletedEntries[0].deletedAt = "2026-07-28T06:00:00Z";
    referenceField.value = referenceTarget.id;
    referenceTemplateFields[0].targetCategory = "Different Category";
    const auto deletedReference = pm::resolveEntryReference(
        referenceField,
        referenceTemplateFields,
        deletedEntries
    );
    assert(deletedReference.has_value());
    assert(deletedReference->status == pm::EntryReferenceStatus::Deleted);
    assert(deletedReference->target.has_value());

    referenceTemplateFields[0].targetCategory = "Servers";
    const auto mismatchedReference = pm::resolveEntryReference(
        referenceField,
        referenceTemplateFields,
        referenceFixture.entries
    );
    assert(mismatchedReference.has_value());
    assert(mismatchedReference->status == pm::EntryReferenceStatus::CategoryMismatch);
    assert(mismatchedReference->target.has_value());

    referenceTemplateFields[0].targetCategory = " \n";
    const auto unrestrictedReference = pm::resolveEntryReference(
        referenceField,
        referenceTemplateFields,
        referenceFixture.entries
    );
    assert(unrestrictedReference.has_value());
    assert(unrestrictedReference->status == pm::EntryReferenceStatus::Resolved);

    pm::VaultEntry displayTarget = pm::makeEntry("Resolved Account", "credential", "target-user", "target-secret");
    displayTarget.id = "raw-resolved-target-id";
    displayTarget.category = "Accounts";
    pm::VaultEntry deletedDisplayTarget = pm::makeEntry("Deleted Account", "credential", "deleted-user", "deleted-secret");
    deletedDisplayTarget.id = "raw-deleted-target-id";
    deletedDisplayTarget.category = "Accounts";
    deletedDisplayTarget.isDeleted = true;
    pm::VaultEntry mismatchedDisplayTarget = pm::makeEntry("Archived Account", "credential", "archive-user", "archive-secret");
    mismatchedDisplayTarget.id = "raw-mismatched-target-id";
    mismatchedDisplayTarget.category = "Archive";
    pm::VaultEntry displaySource = pm::makeEntry("Display Source", "service", "source-user", "source-secret");
    displaySource.id = "display-source-id";
    displaySource.category = "Servers";
    const std::vector<pm::FieldTemplate> displayTemplates = {
        {"template_text", "Notes", "text", "", ""},
        {"template_resolved", "Resolved Owner", "entryReference", "Accounts", ""},
        {"template_empty", "Empty Owner", "entryReference", "Accounts", ""},
        {"template_missing", "Missing Owner", "entryReference", "Accounts", ""},
        {"template_deleted", "Deleted Owner", "entryReference", "Accounts", ""},
        {"template_mismatch", "Mismatched Owner", "entryReference", "Accounts", ""},
        {"template_future", "Future Owner", "futureLink", "Accounts", ""},
    };
    displaySource.customFields = {
        {"field_text", "Notes", "visible-text", "template_text"},
        {"field_resolved", "Resolved Owner", displayTarget.id, "template_resolved"},
        {"field_empty", "Empty Owner", "", "template_empty"},
        {"field_missing", "Missing Owner", "raw-missing-target-id", "template_missing"},
        {"field_deleted", "Deleted Owner", deletedDisplayTarget.id, "template_deleted"},
        {"field_mismatch", "Mismatched Owner", mismatchedDisplayTarget.id, "template_mismatch"},
        {"field_future", "Future Owner", "raw-unknown-value", "template_future"},
        {"field_orphan", "Orphan Owner", "raw-orphan-value", "missing-template"},
        {"field_ad_hoc", "Region", "visible-ad-hoc", ""},
    };
    const std::vector<pm::VaultEntry> displayEntries = {
        displaySource,
        displayTarget,
        deletedDisplayTarget,
        mismatchedDisplayTarget,
    };
    const auto displayFields = pm::projectCustomFieldsForDisplay(
        displaySource.customFields,
        displayTemplates,
        displayEntries
    );
    assert(displayFields[0].value == "visible-text");
    assert(displayFields[1].value == "resolved: Resolved Account - Accounts");
    assert(displayFields[2].value == "empty");
    assert(displayFields[3].value == "missing");
    assert(displayFields[4].value == "deleted");
    assert(displayFields[5].value == "categoryMismatch");
    assert(displayFields[6].value.empty());
    assert(displayFields[7].value.empty());
    assert(displayFields[8].value == "visible-ad-hoc");

    const auto searchFields = pm::projectCustomFieldsForSearch(
        displaySource.customFields,
        displayTemplates,
        displayEntries
    );
    assert(searchFields[1].value == "Resolved Account Accounts");
    for (std::size_t index = 2; index <= 7; ++index) assert(searchFields[index].value.empty());
    assert(searchFields[8].value == "visible-ad-hoc");

    pm::VaultSnapshot displaySnapshot;
    displaySnapshot.entries = displayEntries;
    displaySnapshot.categories = {"Accounts", "Archive", "Servers"};
    displaySnapshot.categoryTemplates = {pm::CategoryTemplate{"Servers", displayTemplates}};
    const auto displayRoundTrip = pm::parseSnapshotJson(pm::serializeSnapshotJson(displaySnapshot));
    assert(displayRoundTrip.entries[0].customFields[1].value == displayTarget.id);
    assert(displayRoundTrip.entries[0].customFields[3].value == "raw-missing-target-id");
    assert(displayRoundTrip.entries[0].customFields[6].value == "raw-unknown-value");
    assert(displayRoundTrip.entries[0].customFields[7].value == "raw-orphan-value");
    for (const auto& forbidden : {
        displayTarget.id,
        std::string("raw-missing-target-id"),
        std::string("raw-unknown-value"),
        std::string("raw-orphan-value"),
    }) {
        const auto matches = pm::filterEntries(
            displaySnapshot.entries,
            displaySnapshot.categoryTemplates,
            forbidden,
            "all"
        );
        assert(std::none_of(matches.begin(), matches.end(), [&](const pm::VaultEntry& candidate) {
            return candidate.id == displaySource.id;
        }));
    }
    const auto resolvedLabelMatches = pm::filterEntries(
        displaySnapshot.entries,
        displaySnapshot.categoryTemplates,
        "Resolved Account",
        "all"
    );
    assert(std::any_of(resolvedLabelMatches.begin(), resolvedLabelMatches.end(), [&](const pm::VaultEntry& candidate) {
        return candidate.id == displaySource.id;
    }));

    auto lifecycleTemplates = referenceFixture.categoryTemplates;
    lifecycleTemplates[1].fields[0].targetCategory = " accounts ";
    lifecycleTemplates[1].fields.push_back(pm::FieldTemplate{
        "template_text",
        "Text",
        "text",
        "Accounts",
        "",
    });
    lifecycleTemplates[1].fields.push_back(pm::FieldTemplate{
        "template_future",
        "Future",
        "futureReference",
        "ACCOUNTS",
        "",
    });
    const auto renamedTemplates = pm::propagateEntryReferenceCategoryRename(
        lifecycleTemplates,
        " ACCOUNTS ",
        " Identity "
    );
    const auto& renamedFields = renamedTemplates[1].fields;
    assert(renamedFields[0].id == lifecycleTemplates[1].fields[0].id);
    assert(renamedFields[0].name == lifecycleTemplates[1].fields[0].name);
    assert(renamedFields[0].valueType == lifecycleTemplates[1].fields[0].valueType);
    assert(renamedFields[0].targetCategory == "Identity");
    const auto renamedTextField = std::find_if(
        renamedFields.begin(),
        renamedFields.end(),
        [](const pm::FieldTemplate& field) { return field.id == "template_text"; }
    );
    const auto renamedFutureField = std::find_if(
        renamedFields.begin(),
        renamedFields.end(),
        [](const pm::FieldTemplate& field) { return field.id == "template_future"; }
    );
    assert(renamedTextField != renamedFields.end());
    assert(renamedTextField->targetCategory == "Accounts");
    assert(renamedFutureField != renamedFields.end());
    assert(renamedFutureField->targetCategory == "ACCOUNTS");

    auto lifecycleEntries = referenceFixture.entries;
    lifecycleEntries[0].category = "Identity";
    referenceField.value = referenceTarget.id;
    const auto renamedReference = pm::resolveEntryReference(
        referenceField,
        renamedFields,
        lifecycleEntries
    );
    assert(renamedReference.has_value());
    assert(renamedReference->status == pm::EntryReferenceStatus::Resolved);
    assert(referenceField.value == referenceTarget.id);

    lifecycleEntries[0].isDeleted = true;
    const auto lifecycleDeleted = pm::resolveEntryReference(
        referenceField,
        renamedFields,
        lifecycleEntries
    );
    assert(lifecycleDeleted.has_value());
    assert(lifecycleDeleted->status == pm::EntryReferenceStatus::Deleted);
    assert(referenceField.value == referenceTarget.id);

    lifecycleEntries[0].isDeleted = false;
    const auto lifecycleRestored = pm::resolveEntryReference(
        referenceField,
        renamedFields,
        lifecycleEntries
    );
    assert(lifecycleRestored.has_value());
    assert(lifecycleRestored->status == pm::EntryReferenceStatus::Resolved);
    assert(referenceField.value == referenceTarget.id);

    lifecycleEntries[0].category.clear();
    const auto categoryDeletedReference = pm::resolveEntryReference(
        referenceField,
        renamedFields,
        lifecycleEntries
    );
    assert(categoryDeletedReference.has_value());
    assert(categoryDeletedReference->status == pm::EntryReferenceStatus::CategoryMismatch);
    assert(renamedFields[0].targetCategory == "Identity");
    assert(referenceField.value == referenceTarget.id);

    lifecycleEntries[0].category = "Archive";
    const auto lifecycleMoved = pm::resolveEntryReference(
        referenceField,
        renamedFields,
        lifecycleEntries
    );
    assert(lifecycleMoved.has_value());
    assert(lifecycleMoved->status == pm::EntryReferenceStatus::CategoryMismatch);
    assert(referenceField.value == referenceTarget.id);

    auto legacyReferenceField = referenceField;
    legacyReferenceField.templateFieldId.clear();
    legacyReferenceField.name = " owner ";
    assert(pm::resolveEntryReference(legacyReferenceField, referenceTemplateFields, referenceFixture.entries).has_value());

    auto invalidReferenceField = legacyReferenceField;
    invalidReferenceField.templateFieldId = "   ";
    assert(!pm::resolveEntryReference(invalidReferenceField, referenceTemplateFields, referenceFixture.entries).has_value());

    auto textTemplateFields = referenceTemplateFields;
    textTemplateFields[0].valueType = "text";
    assert(!pm::resolveEntryReference(referenceField, textTemplateFields, referenceFixture.entries).has_value());

    const auto legacyFixture = pm::parseSnapshotJson(
        readContractFixture("snapshot-legacy-text.json")
    );
    assert(legacyFixture.categoryTemplates.size() == 1);
    assert(legacyFixture.categoryTemplates[0].fields[0].id == "template_owner_team");
    assert(legacyFixture.categoryTemplates[0].fields[0].valueType == "text");
    assert(legacyFixture.categoryTemplates[0].fields[0].targetCategory.empty());
    assert(legacyFixture.categoryTemplates[0].fields[0].targetFieldId.empty());
    assert(legacyFixture.entries[0].customFields[0].templateFieldId.empty());

    const auto emptySlugFixture = pm::parseSnapshotJson(
        readContractFixture("snapshot-legacy-empty-slug.json")
    );
    assert(emptySlugFixture.categoryTemplates[0].fields.size() == 2);
    assert(emptySlugFixture.categoryTemplates[0].fields[0].id == "template_u_f09f9880");
    assert(emptySlugFixture.categoryTemplates[0].fields[1].id == "template_u_212121");
    const auto emptySlugRoundTrip = pm::parseSnapshotJson(pm::serializeSnapshotJson(emptySlugFixture));
    assert(emptySlugRoundTrip.categoryTemplates[0].fields[0].id == "template_u_f09f9880");
    assert(emptySlugRoundTrip.categoryTemplates[0].fields[1].id == "template_u_212121");

    const auto unknownTypeFixture = pm::parseSnapshotJson(
        readContractFixture("snapshot-unknown-value-type.json")
    );
    assert(unknownTypeFixture.categoryTemplates[0].fields[0].valueType == "futureLink");
    const auto unknownTypeRoundTrip = pm::parseSnapshotJson(pm::serializeSnapshotJson(unknownTypeFixture));
    assert(unknownTypeRoundTrip.categoryTemplates[0].fields[0].valueType == "futureLink");
    assert(unknownTypeRoundTrip.categoryTemplates[0].fields[0].targetCategory == "Accounts");
    assert(unknownTypeRoundTrip.categoryTemplates[0].fields[0].targetFieldId.empty());

    const auto referenceSyncJson = pm::serializeSyncPayloadJson(
        pm::VaultSyncPayload{1, "2026-07-28T05:00:00Z", "fixture", 1, referenceFixture}
    );
    const auto referenceSync = pm::parseSyncPayloadJson(referenceSyncJson);
    assert(referenceSync.snapshot.entries[1].customFields[0].templateFieldId == "44444444-4444-4444-8444-444444444444");
    assert(referenceSync.snapshot.categoryTemplates[1].fields[0].valueType == "entryReference");

    const auto fieldReferenceSync = pm::parseSyncPayloadJson(pm::serializeSyncPayloadJson(
        pm::VaultSyncPayload{1, "2026-07-29T05:00:00Z", "fixture", 1, fieldReferenceFixture}
    ));
    assert(fieldReferenceSync.snapshot.categoryTemplates[1].fields[0].targetFieldId == "target_email_field");

    const auto envelopeText = pm::serializeEnvelopeText(envelope);
    const auto parsedEnvelope = pm::parseEnvelopeText(envelopeText);
    const auto parsedLoaded = pm::decryptEnvelope("test-password", parsedEnvelope);
    assert(parsedLoaded.entries.size() == 1);
    assert(parsedLoaded.entries[0].label == "Production Email");

    const std::string testVaultPath = "build/native-core-roundtrip.envelope";
    pm::saveEnvelopeFile(testVaultPath, envelope);
    const auto fileLoaded = pm::decryptEnvelope("test-password", pm::loadEnvelopeFile(testVaultPath));
    assert(fileLoaded.entries.size() == 1);
    assert(fileLoaded.entries[0].username == "admin@example.com");
    std::remove(testVaultPath.c_str());

    pm::VaultSnapshot syncLocal;
    syncLocal.updatedAt = "2026-06-28T00:00:00Z";
    syncLocal.entries.push_back(pm::makeEntry("Local Sync", "credential", "local@example.com", "local-secret"));
    syncLocal.entries[0].id = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb";
    syncLocal.entries[0].category = "Local";
    syncLocal.categories = {"Local"};
    syncLocal.categoryTemplates = {pm::CategoryTemplate{"Local", pm::defaultCategoryFields()}};
    pm::SyncSettingsState syncSettings;
    syncSettings.deviceId = "linux";
    syncSettings.lastSyncRevision = 4;
    syncSettings.hasLocalChanges = true;
    syncSettings.conflictStrategy = "localWins";
    auto missingRemoteSync = pm::synchronizeSnapshots(syncLocal, syncSettings, "");
    assert(missingRemoteSync.uploaded);
    assert(!missingRemoteSync.appliedRemote);
    assert(missingRemoteSync.settings.lastSyncRevision == 4);
    assert(missingRemoteSync.uploadPayloadJson.find("\"revision\":4") != std::string::npos);
    auto missingRemotePayload = pm::parseSyncPayloadJson(missingRemoteSync.uploadPayloadJson);
    assert(missingRemotePayload.deviceId == "linux");
    assert(missingRemotePayload.snapshot.entries.size() == 1);

    pm::VaultSnapshot firstSyncRemote;
    firstSyncRemote.updatedAt = "2026-06-28T00:05:00Z";
    firstSyncRemote.categories = {"Remote Category"};
    firstSyncRemote.categoryTemplates = {
        pm::CategoryTemplate{"Remote Category", pm::defaultCategoryFields()},
    };
    for (const auto remoteRevision : {0, 1}) {
        for (const auto& strategy : {std::string("remoteWins"), std::string("keepBoth")}) {
            for (const auto hasFailedSyncAttempt : {false, true}) {
                pm::SyncSettingsState firstSyncSettings;
                firstSyncSettings.deviceId = "fresh-device";
                firstSyncSettings.lastSyncRevision = 0;
                firstSyncSettings.lastSyncAt = hasFailedSyncAttempt ? "2026-06-28T00:04:00Z" : "";
                firstSyncSettings.lastSyncStatus = hasFailedSyncAttempt ? "error" : "";
                firstSyncSettings.hasLocalChanges = true;
                firstSyncSettings.conflictStrategy = strategy;
                const auto firstSyncPayload = pm::serializeSyncPayloadJson(
                    pm::VaultSyncPayload{1, "2026-06-28T00:05:00Z", "remote", remoteRevision, firstSyncRemote}
                );

                const auto firstSync = pm::synchronizeSnapshots(
                    pm::VaultSnapshot{},
                    firstSyncSettings,
                    firstSyncPayload
                );

                assert(firstSync.snapshot.categories.size() == 1);
                assert(firstSync.snapshot.categories[0] == "Remote Category");
                assert(firstSync.snapshot.categoryTemplates.size() == 1);
                assert(std::none_of(
                    firstSync.snapshot.categoryStates.begin(),
                    firstSync.snapshot.categoryStates.end(),
                    [](const auto& state) { return state.isDeleted; }
                ));
            }
        }
    }

    pm::VaultSnapshot emptyCategoryLocal;
    emptyCategoryLocal.updatedAt = "2026-06-28T00:00:00Z";
    emptyCategoryLocal.categories = {"test"};
    emptyCategoryLocal.categoryTemplates = {pm::CategoryTemplate{"test", pm::defaultCategoryFields()}};
    pm::SyncSettingsState emptyCategorySettings;
    emptyCategorySettings.deviceId = "linux";
    emptyCategorySettings.lastSyncRevision = 1;
    emptyCategorySettings.hasLocalChanges = true;
    emptyCategorySettings.conflictStrategy = "keepBoth";
    auto emptyCategoryUpload = pm::synchronizeSnapshots(emptyCategoryLocal, emptyCategorySettings, "");
    assert(emptyCategoryUpload.uploaded);
    auto emptyCategoryPayload = pm::parseSyncPayloadJson(emptyCategoryUpload.uploadPayloadJson);
    assert(emptyCategoryPayload.snapshot.categories.size() == 1);
    assert(emptyCategoryPayload.snapshot.categories[0] == "test");
    assert(emptyCategoryPayload.snapshot.categoryTemplates.size() == 1);
    assert(emptyCategoryPayload.snapshot.categoryTemplates[0].category == "test");

    pm::VaultSnapshot emptyCategoryRemote;
    emptyCategoryRemote.updatedAt = "2026-06-28T00:05:00Z";
    const auto emptyCategoryRemotePayload = pm::serializeSyncPayloadJson(
        pm::VaultSyncPayload{1, "2026-06-28T00:05:00Z", "remote", 3, emptyCategoryRemote}
    );
    auto emptyCategoryMerge = pm::synchronizeSnapshots(emptyCategoryLocal, emptyCategorySettings, emptyCategoryRemotePayload);
    assert(emptyCategoryMerge.uploaded);
    assert(emptyCategoryMerge.snapshot.categories.size() == 1);
    assert(emptyCategoryMerge.snapshot.categories[0] == "test");
    assert(emptyCategoryMerge.snapshot.categoryTemplates.size() == 1);
    assert(emptyCategoryMerge.snapshot.categoryTemplates[0].fields.size() == 2);

    emptyCategorySettings.hasLocalChanges = false;
    auto cleanEmptyCategoryMerge = pm::synchronizeSnapshots(emptyCategoryLocal, emptyCategorySettings, emptyCategoryRemotePayload);
    assert(cleanEmptyCategoryMerge.uploaded);
    assert(cleanEmptyCategoryMerge.snapshot.categories.size() == 1);
    assert(cleanEmptyCategoryMerge.snapshot.categories[0] == "test");
    assert(cleanEmptyCategoryMerge.snapshot.categoryTemplates.size() == 1);
    assert(cleanEmptyCategoryMerge.snapshot.categoryTemplates[0].fields.size() == 2);

    const auto retainedEmptyCategoryRemotePayload = pm::serializeSyncPayloadJson(
        pm::VaultSyncPayload{1, "2026-06-28T00:05:00Z", "remote", 4, emptyCategoryLocal}
    );
    emptyCategorySettings.hasLocalChanges = true;
    pm::VaultSnapshot deletedEmptyCategoryLocal;
    deletedEmptyCategoryLocal.updatedAt = "2026-06-28T00:06:00Z";
    auto deletedEmptyCategoryMerge = pm::synchronizeSnapshots(deletedEmptyCategoryLocal, emptyCategorySettings, retainedEmptyCategoryRemotePayload);
    assert(deletedEmptyCategoryMerge.uploaded);
    assert(deletedEmptyCategoryMerge.snapshot.categories.empty());
    assert(deletedEmptyCategoryMerge.snapshot.categoryTemplates.empty());

    pm::VaultSnapshot renamedEmptyCategoryLocal;
    renamedEmptyCategoryLocal.updatedAt = "2026-06-28T00:06:00Z";
    renamedEmptyCategoryLocal.categories = {"prod"};
    renamedEmptyCategoryLocal.categoryTemplates = {pm::CategoryTemplate{"prod", pm::defaultCategoryFields()}};
    auto renamedEmptyCategoryMerge = pm::synchronizeSnapshots(renamedEmptyCategoryLocal, emptyCategorySettings, retainedEmptyCategoryRemotePayload);
    assert(renamedEmptyCategoryMerge.uploaded);
    assert(renamedEmptyCategoryMerge.snapshot.categories.size() == 1);
    assert(renamedEmptyCategoryMerge.snapshot.categories[0] == "prod");
    assert(renamedEmptyCategoryMerge.snapshot.categoryTemplates.size() == 1);
    assert(renamedEmptyCategoryMerge.snapshot.categoryTemplates[0].category == "prod");

    const auto deletedCategorySnapshot = pm::parseSnapshotJson(R"json({
        "entries":[{
            "id":"cccccccc-cccc-4ccc-8ccc-cccccccccccc",
            "type":"credential",
            "label":"Category Tombstone",
            "username":"user",
            "secret":"secret",
            "category":"",
            "tags":[],
            "notes":"",
            "customFields":[],
            "isDeleted":false,
            "version":{"macos":2},
            "updatedBy":"macos",
            "createdAt":"2026-06-28T00:00:00Z",
            "updatedAt":"2026-06-28T00:06:00Z"
        }],
        "categories":[],
        "categoryTemplates":[],
        "categoryStates":[{
            "name":"test",
            "isDeleted":true,
            "updatedAt":"2026-06-28T00:06:00Z",
            "version":{"macos":2},
            "updatedBy":"macos"
        }],
        "tags":[],
        "updatedAt":"2026-06-28T00:06:00Z"
    })json");
    const auto staleCategorySnapshot = pm::parseSnapshotJson(R"json({
        "entries":[{
            "id":"cccccccc-cccc-4ccc-8ccc-cccccccccccc",
            "type":"credential",
            "label":"Category Tombstone",
            "username":"user",
            "secret":"secret",
            "category":"test",
            "tags":[],
            "notes":"",
            "customFields":[],
            "isDeleted":false,
            "version":{"macos":1},
            "updatedBy":"macos",
            "createdAt":"2026-06-28T00:00:00Z",
            "updatedAt":"2026-06-28T00:05:00Z"
        }],
        "categories":["test"],
        "categoryTemplates":[{"category":"test","fields":[]}],
        "categoryStates":[{
            "name":"test",
            "isDeleted":false,
            "updatedAt":"2026-06-28T00:05:00Z",
            "version":{"macos":1},
            "updatedBy":"macos"
        }],
        "tags":[],
        "updatedAt":"2026-06-28T00:05:00Z"
    })json");
    for (const auto& strategy : {std::string("remoteWins"), std::string("keepBoth")}) {
        pm::SyncSettingsState deletionSettings;
        deletionSettings.deviceId = "macos";
        deletionSettings.lastSyncRevision = 4;
        deletionSettings.hasLocalChanges = true;
        deletionSettings.conflictStrategy = strategy;
        const auto firstStalePayload = pm::serializeSyncPayloadJson(
            pm::VaultSyncPayload{1, "2026-06-28T00:05:00Z", "remote", 5, staleCategorySnapshot}
        );
        const auto firstDeletionSync = pm::synchronizeSnapshots(
            deletedCategorySnapshot,
            deletionSettings,
            firstStalePayload
        );
        assert(firstDeletionSync.snapshot.categories.empty());
        assert(!firstDeletionSync.settings.hasLocalChanges);

        const auto secondStalePayload = pm::serializeSyncPayloadJson(
            pm::VaultSyncPayload{1, "2026-06-28T00:07:00Z", "remote", 7, staleCategorySnapshot}
        );
        const auto secondDeletionSync = pm::synchronizeSnapshots(
            firstDeletionSync.snapshot,
            firstDeletionSync.settings,
            secondStalePayload
        );
        assert(secondDeletionSync.snapshot.categories.empty());
        assert(secondDeletionSync.snapshot.categoryTemplates.empty());
        assert(secondDeletionSync.snapshot.entries[0].category.empty());

        auto recreatedSnapshot = secondDeletionSync.snapshot;
        assert(pm::addCategory(recreatedSnapshot, "test"));
        auto recreatedSettings = secondDeletionSync.settings;
        recreatedSettings.hasLocalChanges = true;
        const auto recreatedSync = pm::synchronizeSnapshots(
            recreatedSnapshot,
            recreatedSettings,
            secondStalePayload
        );
        assert(recreatedSync.snapshot.categories.size() == 1);
        assert(recreatedSync.snapshot.categories[0] == "test");
    }

    auto runtimeOnlyLocal = deletedCategorySnapshot;
    runtimeOnlyLocal.syncStatus = "Local sync status";
    runtimeOnlyLocal.backupStatus = "Local backup status";
    runtimeOnlyLocal.updatedAt = "2026-06-28T00:09:00Z";
    auto runtimeOnlyRemote = runtimeOnlyLocal;
    runtimeOnlyRemote.syncStatus = "Remote sync status";
    runtimeOnlyRemote.backupStatus = "Remote backup status";
    runtimeOnlyRemote.updatedAt = "2026-06-28T00:08:00Z";
    const auto runtimeOnlyRemotePayload = pm::serializeSyncPayloadJson(
        pm::VaultSyncPayload{1, "2026-06-28T00:08:00Z", "remote", 9, runtimeOnlyRemote}
    );
    for (const auto& strategy : {std::string("remoteWins"), std::string("keepBoth")}) {
        pm::SyncSettingsState runtimeOnlySettings;
        runtimeOnlySettings.deviceId = "linux";
        runtimeOnlySettings.lastSyncRevision = 8;
        runtimeOnlySettings.hasLocalChanges = false;
        runtimeOnlySettings.conflictStrategy = strategy;
        const auto runtimeOnlySync = pm::synchronizeSnapshots(
            runtimeOnlyLocal,
            runtimeOnlySettings,
            runtimeOnlyRemotePayload
        );
        assert(!runtimeOnlySync.uploaded);
        assert(runtimeOnlySync.settings.lastSyncRevision == 9);
        assert(runtimeOnlySync.uploadPayloadJson.empty());
        assert(runtimeOnlySync.snapshot.categories.empty());
        assert(runtimeOnlySync.snapshot.categoryStates.size() == 1);
        assert(runtimeOnlySync.snapshot.categoryStates[0].isDeleted);
    }

    pm::VaultSnapshot remoteDominant;
    remoteDominant.updatedAt = "2026-06-28T00:05:00Z";
    remoteDominant.entries.push_back(pm::makeEntry("Remote Sync", "credential", "remote@example.com", "remote-secret"));
    remoteDominant.entries[0].id = syncLocal.entries[0].id;
    remoteDominant.entries[0].category = "Remote";
    remoteDominant.entries[0].version = {{"linux", 4}, {"android", 2}};
    syncLocal.entries[0].version = {{"linux", 4}, {"android", 1}};
    remoteDominant.categories = {"Remote"};
    remoteDominant.categoryTemplates = {pm::CategoryTemplate{"Remote", pm::categoryFieldsWithCustom({"Owner"})}};
    const auto remotePayloadJson = pm::serializeSyncPayloadJson(pm::VaultSyncPayload{1, "2026-06-28T00:05:00Z", "android", 7, remoteDominant});
    syncSettings.hasLocalChanges = false;
    syncSettings.conflictStrategy = "remoteWins";
    auto remoteOnlySync = pm::synchronizeSnapshots(syncLocal, syncSettings, remotePayloadJson, "etag-1");
    assert(remoteOnlySync.uploaded);
    assert(remoteOnlySync.appliedRemote);
    assert(remoteOnlySync.settings.lastSyncRevision == 8);
    assert(remoteOnlySync.settings.lastRemoteFingerprint.empty());
    assert(remoteOnlySync.snapshot.entries.size() == 1);
    assert(remoteOnlySync.snapshot.entries[0].label == "Remote Sync");
    assert(remoteOnlySync.snapshot.categoryTemplates[0].fields.size() == 3);
    assert(remoteOnlySync.uploadPayloadJson.find("\"isDeleted\":true") != std::string::npos);

    syncSettings.hasLocalChanges = true;
    syncSettings.lastSyncRevision = 7;
    auto localFastPathSync = pm::synchronizeSnapshots(syncLocal, syncSettings, remotePayloadJson);
    assert(localFastPathSync.uploaded);
    assert(!localFastPathSync.appliedRemote);
    assert(localFastPathSync.settings.lastSyncRevision == 8);
    assert(pm::parseSyncPayloadJson(localFastPathSync.uploadPayloadJson).revision == 8);

    pm::VaultSnapshot concurrentRemote = syncLocal;
    concurrentRemote.updatedAt = "2026-06-28T00:10:00Z";
    concurrentRemote.entries[0].label = "Remote Edited Sync";
    concurrentRemote.entries[0].version = {{"linux", 4}, {"android", 2}};
    concurrentRemote.entries[0].updatedBy = "android";
    auto concurrentLocal = syncLocal;
    concurrentLocal.updatedAt = "2026-06-28T00:09:00Z";
    concurrentLocal.entries[0].label = "Local Edited Sync";
    concurrentLocal.entries[0].version = {{"linux", 5}, {"android", 1}};
    concurrentLocal.entries[0].updatedBy = "linux";
    syncSettings.hasLocalChanges = true;
    syncSettings.lastSyncRevision = 7;
    const auto concurrentPayloadJson = pm::serializeSyncPayloadJson(pm::VaultSyncPayload{1, "2026-06-28T00:10:00Z", "android", 9, concurrentRemote});
    auto concurrentSync = pm::synchronizeSnapshots(concurrentLocal, syncSettings, concurrentPayloadJson);
    assert(concurrentSync.uploaded);
    assert(concurrentSync.appliedRemote);
    assert(concurrentSync.settings.lastSyncRevision == 10);
    assert(concurrentSync.stats.conflicts == 1);
    assert(concurrentSync.snapshot.entries.size() == 2);
    assert(concurrentSync.uploadPayloadJson.find("\"revision\":10") != std::string::npos);

    pm::ObjectSyncConfig noneConfig;
    auto noneRequest = pm::buildObjectSyncRequest(noneConfig);
    assert(noneRequest.provider == pm::ObjectSyncProvider::None);
    assert(noneRequest.objectKey == "vault.sync.json");
    assert(noneRequest.baseUrl.empty());
    assert(noneRequest.objectUrl.empty());
    assert(!noneRequest.requiresCredentials);

    pm::ObjectSyncConfig webDavConfig;
    webDavConfig.provider = pm::ObjectSyncProvider::WebDav;
    webDavConfig.endpoint = "https://dav.example.com/remote.php/dav/files/me/";
    webDavConfig.objectKey = "/vaults/primary.json";
    auto webDavRequest = pm::buildObjectSyncRequest(webDavConfig);
    assert(webDavRequest.baseUrl == "https://dav.example.com/remote.php/dav/files/me");
    assert(webDavRequest.objectUrl == "https://dav.example.com/remote.php/dav/files/me/vaults/primary.json");
    assert(!webDavRequest.requiresCredentials);

    pm::ObjectSyncConfig s3Config;
    s3Config.provider = pm::ObjectSyncProvider::S3Presigned;
    s3Config.customUrl = "https://s3.example.com/presigned/vault";
    auto s3Request = pm::buildObjectSyncRequest(s3Config);
    assert(s3Request.objectKey == "vault.sync.json");
    assert(s3Request.objectUrl == "https://s3.example.com/presigned/vault/vault.sync.json");
    assert(!s3Request.requiresCredentials);

    pm::ObjectSyncConfig cosConfig;
    cosConfig.provider = pm::ObjectSyncProvider::TencentCos;
    cosConfig.accessKeyId = "ak";
    cosConfig.secretAccessKey = "sk";
    cosConfig.bucket = "vault-1250000000";
    cosConfig.endpoint = "https://cos.ap-shanghai.myqcloud.com";
    cosConfig.appId = "1250000000";
    cosConfig.objectKey = "prod/vault.json";
    auto cosRequest = pm::buildObjectSyncRequest(cosConfig);
    assert(cosRequest.baseUrl == "https://vault-1250000000.cos.ap-shanghai.myqcloud.com");
    assert(cosRequest.objectUrl == "https://vault-1250000000.cos.ap-shanghai.myqcloud.com/prod/vault.json");
    assert(cosRequest.requiresCredentials);
    cosConfig.bucket = "vault";
    cosConfig.endpoint = "cos.ap-shanghai.myqcloud.com";
    auto cosSigned = pm::buildObjectSyncSignedRequest(cosConfig, "GET", "", 1782604800);
    assert(cosSigned.objectUrl == "https://vault-1250000000.cos.ap-shanghai.myqcloud.com/prod/vault.json");
    assert(cosSigned.method == "GET");
    assert(cosSigned.headers.at("Host") == "vault-1250000000.cos.ap-shanghai.myqcloud.com");
    assert(cosSigned.headers.at("Authorization").find("q-sign-algorithm=sha1") != std::string::npos);
    assert(cosSigned.headers.at("Authorization").find("q-ak=ak") != std::string::npos);

    pm::ObjectSyncConfig ossConfig;
    ossConfig.provider = pm::ObjectSyncProvider::AliyunOss;
    ossConfig.accessKeyId = "ak";
    ossConfig.secretAccessKey = "sk";
    ossConfig.bucket = "vault";
    ossConfig.customUrl = "https://vault.oss-cn-hangzhou.aliyuncs.com/base/";
    auto ossRequest = pm::buildObjectSyncRequest(ossConfig);
    assert(ossRequest.baseUrl == "https://vault.oss-cn-hangzhou.aliyuncs.com/base");
    assert(ossRequest.objectUrl == "https://vault.oss-cn-hangzhou.aliyuncs.com/base/vault.sync.json");
    assert(ossRequest.requiresCredentials);
    auto ossSigned = pm::buildObjectSyncSignedRequest(ossConfig, "PUT", R"({"revision":2})", 1782604800);
    assert(ossSigned.method == "PUT");
    assert(ossSigned.body == R"({"revision":2})");
    assert(ossSigned.headers.at("Host") == "vault.oss-cn-hangzhou.aliyuncs.com");
    assert(ossSigned.headers.at("Content-Type") == "application/json");
    assert(ossSigned.headers.at("x-oss-date") == "20260628T000000Z");
    assert(!ossSigned.headers.at("x-oss-content-sha256").empty());
    assert(ossSigned.headers.at("Authorization").find("OSS4-HMAC-SHA256 Credential=ak/20260628/cn-hangzhou/oss/aliyun_v4_request") == 0);

    bool missingCredentialsRejected = false;
    try {
        pm::ObjectSyncConfig invalidCos;
        invalidCos.provider = pm::ObjectSyncProvider::TencentCos;
        invalidCos.bucket = "vault";
        invalidCos.endpoint = "https://cos.example.com";
        (void)pm::buildObjectSyncRequest(invalidCos);
    } catch (const std::exception&) {
        missingCredentialsRejected = true;
    }
    assert(missingCredentialsRejected);

    bool missingUrlRejected = false;
    try {
        pm::ObjectSyncConfig invalidWebDav;
        invalidWebDav.provider = pm::ObjectSyncProvider::WebDav;
        (void)pm::buildObjectSyncRequest(invalidWebDav);
    } catch (const std::exception&) {
        missingUrlRejected = true;
    }
    assert(missingUrlRejected);

    std::cout << "native core tests passed\n";
    return 0;
}
