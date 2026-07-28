#pragma once

#include <cstdint>
#include <ctime>
#include <map>
#include <optional>
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

struct CustomField {
    std::string id;
    std::string name;
    std::string value;
    std::string templateFieldId;
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
    std::string payloadJson;
    std::vector<CustomField> customFields;
    std::map<std::string, int> version;
    std::string updatedBy = "native-cli";
    std::string createdAt;
    std::string updatedAt;
    std::string deletedAt;
    bool isDeleted = false;
};

struct FieldTemplate {
    std::string id;
    std::string name;
    std::string valueType = "text";
    std::string targetCategory;
};

enum class EntryReferenceStatus {
    Empty,
    Resolved,
    Missing,
    Deleted,
    CategoryMismatch,
};

struct EntryReferenceTarget {
    std::string id;
    std::string label;
    std::string category;
};

struct EntryReferenceResolution {
    EntryReferenceStatus status = EntryReferenceStatus::Empty;
    std::optional<EntryReferenceTarget> target;
};

struct CategoryTemplate {
    std::string category;
    std::vector<FieldTemplate> fields;
};

enum class CategoryTypePreset {
    Server,
    Service,
    Account,
};

struct VaultSnapshot {
    std::vector<VaultEntry> entries;
    std::vector<std::string> categories;
    std::vector<CategoryTemplate> categoryTemplates;
    std::vector<std::string> tags;
    bool requireTotp = false;
    std::string totpSecret;
    std::string syncStatus = "Not configured";
    std::string backupStatus = "No backup has run";
    std::string updatedAt;
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

struct VaultSyncPayload {
    int version = 1;
    std::string exportedAt;
    std::string deviceId;
    int revision = 0;
    VaultSnapshot snapshot;
};

struct SyncSettingsState {
    std::string deviceId = "native-cli";
    int lastSyncRevision = 0;
    bool hasLocalChanges = true;
    std::string conflictStrategy = "localWins";
    std::string lastRemoteFingerprint;
    std::string lastSyncStatus;
    std::string lastSyncMessage;
    std::string lastSyncAt;
};

struct SnapshotSyncResult {
    VaultSnapshot snapshot;
    SyncSettingsState settings;
    SyncMergeStats stats;
    bool uploaded = false;
    bool appliedRemote = false;
    std::string uploadPayloadJson;
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
VaultSnapshot parseSnapshotJson(const std::string& json);
std::string serializeEnvelopeText(const VaultEnvelope& envelope);
VaultEnvelope parseEnvelopeText(const std::string& text);
void saveEnvelopeFile(const std::string& path, const VaultEnvelope& envelope);
VaultEnvelope loadEnvelopeFile(const std::string& path);
VaultEntry makeEntry(const std::string& label, const std::string& type, const std::string& username, const std::string& secret);
std::optional<EntryReferenceResolution> resolveEntryReference(
    const CustomField& field,
    const std::vector<FieldTemplate>& templateFields,
    const std::vector<VaultEntry>& entries
);
std::vector<CategoryTemplate> propagateEntryReferenceCategoryRename(
    const std::vector<CategoryTemplate>& templates,
    const std::string& oldCategory,
    const std::string& newCategory
);
std::vector<CustomField> remapEntryReferenceIds(
    const std::vector<CustomField>& fields,
    const std::vector<FieldTemplate>& templateFields,
    const std::map<std::string, std::string>& idMap
);
std::vector<FieldTemplate> defaultCategoryFields();
std::vector<FieldTemplate> categoryFieldsForPreset(CategoryTypePreset preset, const std::vector<std::string>& customFieldNames = {});
std::vector<FieldTemplate> categoryFieldsWithCustom(const std::vector<std::string>& customFieldNames);
bool addCategory(VaultSnapshot& snapshot, const std::string& category, const std::vector<FieldTemplate>& fields = defaultCategoryFields());
bool addCategory(VaultSnapshot& snapshot, const std::string& category, CategoryTypePreset preset, const std::vector<std::string>& customFieldNames = {});
std::vector<VaultEntry> filterEntries(const std::vector<VaultEntry>& entries, const std::string& query, const std::string& type = "all");
std::vector<VaultEntry> filterEntries(
    const std::vector<VaultEntry>& entries,
    const std::vector<CategoryTemplate>& categoryTemplates,
    const std::string& query,
    const std::string& type = "all"
);
std::vector<std::string> rebuildCategories(const std::vector<VaultEntry>& entries);
std::vector<std::string> rebuildCategories(const std::vector<VaultEntry>& entries, const std::vector<CategoryTemplate>& categoryTemplates);
std::vector<std::string> rebuildTags(const std::vector<VaultEntry>& entries);
std::string generateTotp(const std::string& base32Secret, std::uint64_t unixSeconds);
bool verifyTotp(const std::string& base32Secret, const std::string& code, std::uint64_t unixSeconds);
std::string compareVersion(const std::map<std::string, int>& local, const std::map<std::string, int>& remote);
SyncMergeResult mergeEntries(const std::vector<VaultEntry>& local, const std::vector<VaultEntry>& remote, const std::string& strategy);
std::string serializeSyncPayloadJson(const VaultSyncPayload& payload);
VaultSyncPayload parseSyncPayloadJson(const std::string& json);
SnapshotSyncResult synchronizeSnapshots(
    const VaultSnapshot& localSnapshot,
    const SyncSettingsState& settings,
    const std::string& remotePayloadJson,
    const std::string& remoteFingerprint = ""
);
ObjectSyncRequest buildObjectSyncRequest(const ObjectSyncConfig& config);
ObjectSyncRequest buildObjectSyncSignedRequest(
    const ObjectSyncConfig& config,
    const std::string& method,
    const std::string& body = "",
    std::time_t now = std::time(nullptr)
);

} // namespace pm
