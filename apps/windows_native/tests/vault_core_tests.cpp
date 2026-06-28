#include "../src/vault_core.hpp"

#include <cassert>
#include <iostream>
#include <stdexcept>

int main() {
    pm::VaultSnapshot snapshot;
    auto entry = pm::makeEntry("Production Email", "credential", "admin@example.com", "secret-password");
    entry.category = "Work";
    entry.tags = {"mail", "shared"};
    snapshot.entries.push_back(entry);

    auto envelope = pm::createEnvelope("test-password", snapshot);
    assert(envelope.masterKeyRecord.iterations == pm::kDefaultIterations);
    assert(!envelope.encryptedVault.ciphertextBase64.empty());
    auto loaded = pm::decryptEnvelope("test-password", envelope);
    assert(loaded.syncStatus == "Loaded");
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

    std::cout << "windows-native core tests passed\n";
    return 0;
}
