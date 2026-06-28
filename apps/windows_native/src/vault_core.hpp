#pragma once

#include <cstdint>
#include <ctime>
#include <map>
#include <string>
#include <vector>

namespace pm {

constexpr int kDefaultIterations = 600000;

struct EncryptedPayload {
    std::string ciphertextBase64;
    std::string nonceBase64;
    std::string macBase64;
    int version = 1;
};

struct MasterKeyRecord {
    std::string saltBase64;
    int iterations = kDefaultIterations;
    std::string verifierBase64;
    std::string metadataSaltBase64;
    int metadataIterations = kDefaultIterations;
};

struct VaultEntry {
    std::string id;
    std::string label;
    std::string type;
    std::string username;
    std::string secret;
    std::string category;
    std::vector<std::string> tags;
    std::string notes;
    std::map<std::string, int> version;
    std::string updatedBy = "linux-native";
    bool isDeleted = false;
};

struct VaultSnapshot {
    std::vector<VaultEntry> entries;
    std::vector<std::string> categories;
    std::vector<std::string> tags;
    bool requireTotp = false;
    std::string totpSecret;
    std::string syncStatus = "Not configured";
    std::string backupStatus = "No backup has run";
};

struct VaultEnvelope {
    int schemaVersion = 1;
    MasterKeyRecord masterKeyRecord;
    EncryptedPayload encryptedVault;
    std::string updatedAt;
};

struct SyncMergeStats {
    int total = 0;
    int conflicts = 0;
    int deletes = 0;
};

struct SyncMergeResult {
    std::vector<VaultEntry> entries;
    SyncMergeStats stats;
};

enum class ObjectSyncProvider {
    None,
    WebDav,
    S3Presigned,
    TencentCos,
    AliyunOss,
};

struct ObjectSyncConfig {
    ObjectSyncProvider provider = ObjectSyncProvider::None;
    std::string accessKeyId;
    std::string secretAccessKey;
    std::string bucket;
    std::string endpoint;
    std::string appId;
    std::string customUrl;
    std::string objectKey;
};

struct ObjectSyncRequest {
    ObjectSyncProvider provider = ObjectSyncProvider::None;
    std::string objectKey;
    std::string baseUrl;
    std::string objectUrl;
    bool requiresCredentials = false;
    std::string method;
    std::map<std::string, std::string> headers;
    std::string body;
};

std::string randomId();
std::string isoTimestamp(std::time_t now = std::time(nullptr));
std::string base64Encode(const std::vector<std::uint8_t>& bytes);
std::vector<std::uint8_t> base64Decode(const std::string& value);
std::vector<std::uint8_t> deriveKey(const std::string& password, const std::vector<std::uint8_t>& salt, int iterations);
MasterKeyRecord makeMasterKeyRecord(const std::string& password, int iterations = kDefaultIterations);
std::vector<std::uint8_t> verifyPassword(const std::string& password, const MasterKeyRecord& record);
EncryptedPayload encryptBytes(const std::vector<std::uint8_t>& plaintext, const std::vector<std::uint8_t>& key);
std::vector<std::uint8_t> decryptBytes(const EncryptedPayload& payload, const std::vector<std::uint8_t>& key);
VaultEnvelope createEnvelope(const std::string& password, const VaultSnapshot& snapshot);
VaultSnapshot decryptEnvelope(const std::string& password, const VaultEnvelope& envelope);
std::string serializeSnapshotJson(const VaultSnapshot& snapshot);
VaultEntry makeEntry(const std::string& label, const std::string& type, const std::string& username, const std::string& secret);
std::vector<VaultEntry> filterEntries(const std::vector<VaultEntry>& entries, const std::string& query, const std::string& type = "all");
std::vector<std::string> rebuildCategories(const std::vector<VaultEntry>& entries);
std::vector<std::string> rebuildTags(const std::vector<VaultEntry>& entries);
std::string generateTotp(const std::string& base32Secret, std::uint64_t unixSeconds);
bool verifyTotp(const std::string& base32Secret, const std::string& code, std::uint64_t unixSeconds);
std::string compareVersion(const std::map<std::string, int>& local, const std::map<std::string, int>& remote);
SyncMergeResult mergeEntries(const std::vector<VaultEntry>& local, const std::vector<VaultEntry>& remote, const std::string& strategy);
ObjectSyncRequest buildObjectSyncRequest(const ObjectSyncConfig& config);
ObjectSyncRequest buildObjectSyncSignedRequest(
    const ObjectSyncConfig& config,
    const std::string& method,
    const std::string& body = "",
    std::time_t now = std::time(nullptr)
);

} // namespace pm
