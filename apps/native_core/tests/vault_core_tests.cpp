#include "../src/vault_core.hpp"

#include <cassert>
#include <cstdio>
#include <iostream>
#include <stdexcept>

int main() {
    pm::VaultSnapshot snapshot;
    auto entry = pm::makeEntry("Production Email", "credential", "admin@example.com", "secret-password");
    entry.category = "Work";
    entry.tags = {"mail", "shared"};
    entry.notes = "owner:sre-team";
    entry.customFields = {pm::CustomField{"11111111-1111-4111-8111-111111111111", "Owner", "SRE"}};
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
    remote.version = {{"linux", 1}, {"remote", 2}};
    remote.updatedBy = "remote";
    assert(pm::compareVersion(local.version, remote.version) == "concurrent");
    auto merged = pm::mergeEntries({local}, {remote}, "localWins");
    assert(merged.stats.conflicts == 1);
    assert(merged.entries.size() == 2);
    assert(merged.entries[1].label.find("Remote") != std::string::npos);

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
