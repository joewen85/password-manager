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
    const auto referenceRoundTrip = pm::parseSnapshotJson(pm::serializeSnapshotJson(referenceFixture));
    assert(referenceRoundTrip.entries[0].id == "harmony_target_01");
    assert(referenceRoundTrip.entries[1].customFields[0].templateFieldId == "44444444-4444-4444-8444-444444444444");
    assert(referenceRoundTrip.categoryTemplates[1].fields[0].valueType == "entryReference");

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

    auto lifecycleTemplates = referenceFixture.categoryTemplates;
    lifecycleTemplates[1].fields[0].targetCategory = " accounts ";
    lifecycleTemplates[1].fields.push_back(pm::FieldTemplate{
        "template_text",
        "Text",
        "text",
        "Accounts",
    });
    lifecycleTemplates[1].fields.push_back(pm::FieldTemplate{
        "template_future",
        "Future",
        "futureReference",
        "ACCOUNTS",
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

    const auto referenceSyncJson = pm::serializeSyncPayloadJson(
        pm::VaultSyncPayload{1, "2026-07-28T05:00:00Z", "fixture", 1, referenceFixture}
    );
    const auto referenceSync = pm::parseSyncPayloadJson(referenceSyncJson);
    assert(referenceSync.snapshot.entries[1].customFields[0].templateFieldId == "44444444-4444-4444-8444-444444444444");
    assert(referenceSync.snapshot.categoryTemplates[1].fields[0].valueType == "entryReference");

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
    auto remoteOnlySync = pm::synchronizeSnapshots(syncLocal, syncSettings, remotePayloadJson, "etag-1");
    assert(!remoteOnlySync.uploaded);
    assert(remoteOnlySync.appliedRemote);
    assert(remoteOnlySync.settings.lastSyncRevision == 7);
    assert(remoteOnlySync.settings.lastRemoteFingerprint == "etag-1");
    assert(remoteOnlySync.snapshot.entries.size() == 1);
    assert(remoteOnlySync.snapshot.entries[0].label == "Remote Sync");
    assert(remoteOnlySync.snapshot.categoryTemplates[0].fields.size() == 3);

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
