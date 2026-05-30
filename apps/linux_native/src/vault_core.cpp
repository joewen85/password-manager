#include "vault_core.hpp"

#include <algorithm>
#include <cctype>
#include <iomanip>
#include <openssl/evp.h>
#include <openssl/hmac.h>
#include <openssl/rand.h>
#include <openssl/sha.h>
#include <set>
#include <sstream>
#include <stdexcept>

namespace pm {
namespace {

std::vector<std::uint8_t> randomBytes(std::size_t count) {
    std::vector<std::uint8_t> bytes(count);
    if (RAND_bytes(bytes.data(), static_cast<int>(bytes.size())) != 1) {
        throw std::runtime_error("Secure random generation failed.");
    }
    return bytes;
}

bool constantTimeEqual(const std::vector<std::uint8_t>& left, const std::vector<std::uint8_t>& right) {
    if (left.size() != right.size()) return false;
    std::uint8_t diff = 0;
    for (std::size_t index = 0; index < left.size(); ++index) {
        diff |= left[index] ^ right[index];
    }
    return diff == 0;
}

std::string escapeJson(const std::string& value) {
    std::ostringstream out;
    for (char ch : value) {
        switch (ch) {
            case '\\': out << "\\\\"; break;
            case '"': out << "\\\""; break;
            case '\n': out << "\\n"; break;
            case '\r': out << "\\r"; break;
            case '\t': out << "\\t"; break;
            default: out << ch;
        }
    }
    return out.str();
}

std::string trimCopy(const std::string& value) {
    const auto first = value.find_first_not_of(" \t\n\r\f\v");
    if (first == std::string::npos) return "";
    const auto last = value.find_last_not_of(" \t\n\r\f\v");
    return value.substr(first, last - first + 1);
}

std::string canonicalIdString(const std::string& value) {
    std::string normalized = trimCopy(value);
    std::transform(normalized.begin(), normalized.end(), normalized.begin(), [](unsigned char ch) {
        return static_cast<char>(std::tolower(ch));
    });
    return normalized;
}

VaultEntry canonicalEntryId(const VaultEntry& entry) {
    VaultEntry copy = entry;
    copy.id = canonicalIdString(entry.id);
    return copy;
}

std::vector<std::uint8_t> decodeBase32(const std::string& secret) {
    const std::string alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";
    std::string bits;
    for (char raw : secret) {
        if (raw == '=' || raw == ' ' || raw == '-') continue;
        char ch = static_cast<char>(std::toupper(static_cast<unsigned char>(raw)));
        auto pos = alphabet.find(ch);
        if (pos == std::string::npos) throw std::runtime_error("TOTP secret is not valid Base32.");
        for (int bit = 4; bit >= 0; --bit) bits.push_back(((pos >> bit) & 1U) ? '1' : '0');
    }
    std::vector<std::uint8_t> bytes;
    for (std::size_t index = 0; index + 8 <= bits.size(); index += 8) {
        std::uint8_t value = 0;
        for (std::size_t bit = 0; bit < 8; ++bit) value = static_cast<std::uint8_t>((value << 1) | (bits[index + bit] == '1'));
        bytes.push_back(value);
    }
    return bytes;
}

std::map<std::string, int> effectiveVersion(const VaultEntry& entry) {
    if (!entry.version.empty()) return entry.version;
    return {{entry.updatedBy.empty() ? "legacy" : entry.updatedBy, 1}};
}

const VaultEntry& pickLatest(const VaultEntry& local, const VaultEntry& remote) {
    return local.id >= remote.id ? local : remote;
}

VaultEntry pickDuplicateEntry(const VaultEntry& existing, const VaultEntry& candidate) {
    auto comparison = compareVersion(effectiveVersion(existing), effectiveVersion(candidate));
    if (comparison == "localDominates") return existing;
    if (comparison == "remoteDominates") return candidate;
    return pickLatest(existing, candidate);
}

VaultEntry conflictCopy(const VaultEntry& entry) {
    VaultEntry copy = entry;
    copy.id = randomId();
    copy.label += " (conflict-" + (entry.updatedBy.empty() ? "unknown" : entry.updatedBy) + ")";
    return copy;
}

} // namespace

std::string randomId() {
    auto bytes = randomBytes(16);
    std::ostringstream out;
    for (auto byte : bytes) out << std::hex << std::setw(2) << std::setfill('0') << static_cast<int>(byte);
    return out.str();
}

std::string isoTimestamp(std::time_t now) {
    std::tm tm{};
    gmtime_r(&now, &tm);
    std::ostringstream out;
    out << std::put_time(&tm, "%Y-%m-%dT%H:%M:%SZ");
    return out.str();
}

std::string base64Encode(const std::vector<std::uint8_t>& bytes) {
    std::string output(4 * ((bytes.size() + 2) / 3), '\0');
    int length = EVP_EncodeBlock(reinterpret_cast<unsigned char*>(output.data()), bytes.data(), static_cast<int>(bytes.size()));
    output.resize(static_cast<std::size_t>(length));
    return output;
}

std::vector<std::uint8_t> base64Decode(const std::string& value) {
    std::vector<std::uint8_t> output(3 * value.size() / 4 + 3);
    int length = EVP_DecodeBlock(output.data(), reinterpret_cast<const unsigned char*>(value.data()), static_cast<int>(value.size()));
    if (length < 0) throw std::runtime_error("Base64 decode failed.");
    int padding = 0;
    if (!value.empty() && value.back() == '=') ++padding;
    if (value.size() > 1 && value[value.size() - 2] == '=') ++padding;
    output.resize(static_cast<std::size_t>(length - padding));
    return output;
}

std::vector<std::uint8_t> deriveKey(const std::string& password, const std::vector<std::uint8_t>& salt, int iterations) {
    std::vector<std::uint8_t> key(32);
    if (PKCS5_PBKDF2_HMAC(password.c_str(), static_cast<int>(password.size()), salt.data(), static_cast<int>(salt.size()), iterations, EVP_sha256(), static_cast<int>(key.size()), key.data()) != 1) {
        throw std::runtime_error("PBKDF2 derivation failed.");
    }
    return key;
}

MasterKeyRecord makeMasterKeyRecord(const std::string& password, int iterations) {
    auto salt = randomBytes(16);
    auto metadataSalt = randomBytes(16);
    auto verifier = deriveKey(password, salt, iterations);
    return MasterKeyRecord{base64Encode(salt), iterations, base64Encode(verifier), base64Encode(metadataSalt), iterations};
}

std::vector<std::uint8_t> verifyPassword(const std::string& password, const MasterKeyRecord& record) {
    auto derived = deriveKey(password, base64Decode(record.saltBase64), record.iterations);
    if (!constantTimeEqual(derived, base64Decode(record.verifierBase64))) {
        throw std::runtime_error("Vault authentication failed.");
    }
    return derived;
}

EncryptedPayload encryptBytes(const std::vector<std::uint8_t>& plaintext, const std::vector<std::uint8_t>& key) {
    auto nonce = randomBytes(12);
    std::vector<std::uint8_t> ciphertext(plaintext.size());
    std::vector<std::uint8_t> tag(16);
    int length = 0;
    int ciphertextLength = 0;
    EVP_CIPHER_CTX* ctx = EVP_CIPHER_CTX_new();
    if (!ctx) throw std::runtime_error("AES context allocation failed.");
    if (EVP_EncryptInit_ex(ctx, EVP_aes_256_gcm(), nullptr, nullptr, nullptr) != 1 ||
        EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_SET_IVLEN, static_cast<int>(nonce.size()), nullptr) != 1 ||
        EVP_EncryptInit_ex(ctx, nullptr, nullptr, key.data(), nonce.data()) != 1 ||
        EVP_EncryptUpdate(ctx, ciphertext.data(), &length, plaintext.data(), static_cast<int>(plaintext.size())) != 1) {
        EVP_CIPHER_CTX_free(ctx);
        throw std::runtime_error("AES-GCM encryption failed.");
    }
    ciphertextLength = length;
    if (EVP_EncryptFinal_ex(ctx, ciphertext.data() + length, &length) != 1 ||
        EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_GET_TAG, static_cast<int>(tag.size()), tag.data()) != 1) {
        EVP_CIPHER_CTX_free(ctx);
        throw std::runtime_error("AES-GCM finalization failed.");
    }
    ciphertext.resize(static_cast<std::size_t>(ciphertextLength + length));
    EVP_CIPHER_CTX_free(ctx);
    return EncryptedPayload{base64Encode(ciphertext), base64Encode(nonce), base64Encode(tag), 1};
}

std::vector<std::uint8_t> decryptBytes(const EncryptedPayload& payload, const std::vector<std::uint8_t>& key) {
    auto ciphertext = base64Decode(payload.ciphertextBase64);
    auto nonce = base64Decode(payload.nonceBase64);
    auto tag = base64Decode(payload.macBase64);
    std::vector<std::uint8_t> plaintext(ciphertext.size());
    int length = 0;
    int plaintextLength = 0;
    EVP_CIPHER_CTX* ctx = EVP_CIPHER_CTX_new();
    if (!ctx) throw std::runtime_error("AES context allocation failed.");
    if (EVP_DecryptInit_ex(ctx, EVP_aes_256_gcm(), nullptr, nullptr, nullptr) != 1 ||
        EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_SET_IVLEN, static_cast<int>(nonce.size()), nullptr) != 1 ||
        EVP_DecryptInit_ex(ctx, nullptr, nullptr, key.data(), nonce.data()) != 1 ||
        EVP_DecryptUpdate(ctx, plaintext.data(), &length, ciphertext.data(), static_cast<int>(ciphertext.size())) != 1) {
        EVP_CIPHER_CTX_free(ctx);
        throw std::runtime_error("AES-GCM decryption failed.");
    }
    plaintextLength = length;
    if (EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_SET_TAG, static_cast<int>(tag.size()), tag.data()) != 1 ||
        EVP_DecryptFinal_ex(ctx, plaintext.data() + length, &length) != 1) {
        EVP_CIPHER_CTX_free(ctx);
        throw std::runtime_error("AES-GCM authentication failed.");
    }
    plaintext.resize(static_cast<std::size_t>(plaintextLength + length));
    EVP_CIPHER_CTX_free(ctx);
    return plaintext;
}

VaultEnvelope createEnvelope(const std::string& password, const VaultSnapshot& snapshot) {
    auto record = makeMasterKeyRecord(password);
    auto key = verifyPassword(password, record);
    auto raw = serializeSnapshotJson(snapshot);
    return VaultEnvelope{1, record, encryptBytes(std::vector<std::uint8_t>(raw.begin(), raw.end()), key), isoTimestamp()};
}

VaultSnapshot decryptEnvelope(const std::string& password, const VaultEnvelope& envelope) {
    auto key = verifyPassword(password, envelope.masterKeyRecord);
    auto raw = decryptBytes(envelope.encryptedVault, key);
    VaultSnapshot snapshot;
    snapshot.syncStatus = std::string(raw.begin(), raw.end()).find("entries") != std::string::npos ? "Loaded" : "Not configured";
    return snapshot;
}

std::string serializeSnapshotJson(const VaultSnapshot& snapshot) {
    std::ostringstream out;
    out << "{\"entries\":[";
    for (std::size_t index = 0; index < snapshot.entries.size(); ++index) {
        const auto& entry = snapshot.entries[index];
        if (index > 0) out << ",";
        out << "{\"id\":\"" << escapeJson(canonicalIdString(entry.id)) << "\",\"label\":\"" << escapeJson(entry.label)
            << "\",\"type\":\"" << escapeJson(entry.type) << "\",\"username\":\"" << escapeJson(entry.username)
            << "\",\"secret\":\"" << escapeJson(entry.secret) << "\",\"category\":\"" << escapeJson(entry.category)
            << "\",\"isDeleted\":" << (entry.isDeleted ? "true" : "false") << "}";
    }
    out << "],\"syncStatus\":\"" << escapeJson(snapshot.syncStatus) << "\",\"backupStatus\":\"" << escapeJson(snapshot.backupStatus) << "\"}";
    return out.str();
}

VaultEntry makeEntry(const std::string& label, const std::string& type, const std::string& username, const std::string& secret) {
    VaultEntry entry;
    entry.id = randomId();
    entry.label = label;
    entry.type = type;
    entry.username = username;
    entry.secret = secret;
    return entry;
}

std::vector<VaultEntry> filterEntries(const std::vector<VaultEntry>& entries, const std::string& query, const std::string& type) {
    std::vector<VaultEntry> result;
    for (const auto& entry : entries) {
        if (entry.isDeleted) continue;
        if (type != "all" && entry.type != type) continue;
        std::string haystack = entry.label + " " + entry.type + " " + entry.category;
        if (query.empty() || haystack.find(query) != std::string::npos) result.push_back(entry);
    }
    return result;
}

std::vector<std::string> rebuildCategories(const std::vector<VaultEntry>& entries) {
    std::set<std::string> values;
    for (const auto& entry : entries) if (!entry.isDeleted && !entry.category.empty()) values.insert(entry.category);
    return {values.begin(), values.end()};
}

std::vector<std::string> rebuildTags(const std::vector<VaultEntry>& entries) {
    std::set<std::string> values;
    for (const auto& entry : entries) if (!entry.isDeleted) values.insert(entry.tags.begin(), entry.tags.end());
    return {values.begin(), values.end()};
}

std::string generateTotp(const std::string& base32Secret, std::uint64_t unixSeconds) {
    auto key = decodeBase32(base32Secret);
    std::uint64_t counter = unixSeconds / 30;
    unsigned char counterBytes[8]{};
    for (int i = 7; i >= 0; --i) {
        counterBytes[i] = static_cast<unsigned char>(counter & 0xff);
        counter >>= 8;
    }
    unsigned int length = 0;
    unsigned char digest[EVP_MAX_MD_SIZE]{};
    HMAC(EVP_sha1(), key.data(), static_cast<int>(key.size()), counterBytes, 8, digest, &length);
    int offset = digest[length - 1] & 0x0f;
    int binary = ((digest[offset] & 0x7f) << 24) | ((digest[offset + 1] & 0xff) << 16) | ((digest[offset + 2] & 0xff) << 8) | (digest[offset + 3] & 0xff);
    std::ostringstream out;
    out << std::setw(6) << std::setfill('0') << (binary % 1000000);
    return out.str();
}

bool verifyTotp(const std::string& base32Secret, const std::string& code, std::uint64_t unixSeconds) {
    return generateTotp(base32Secret, unixSeconds - 30) == code ||
           generateTotp(base32Secret, unixSeconds) == code ||
           generateTotp(base32Secret, unixSeconds + 30) == code;
}

std::string compareVersion(const std::map<std::string, int>& local, const std::map<std::string, int>& remote) {
    bool localGreater = false;
    bool remoteGreater = false;
    std::set<std::string> keys;
    for (const auto& [key, _] : local) keys.insert(key);
    for (const auto& [key, _] : remote) keys.insert(key);
    for (const auto& key : keys) {
        int left = local.count(key) ? local.at(key) : 0;
        int right = remote.count(key) ? remote.at(key) : 0;
        if (left > right) localGreater = true;
        if (right > left) remoteGreater = true;
        if (localGreater && remoteGreater) return "concurrent";
    }
    if (!localGreater && !remoteGreater) return "equal";
    return localGreater ? "localDominates" : "remoteDominates";
}

SyncMergeResult mergeEntries(const std::vector<VaultEntry>& local, const std::vector<VaultEntry>& remote, const std::string& strategy) {
    std::vector<VaultEntry> merged;
    std::map<std::string, VaultEntry> remoteById;
    for (const auto& entry : remote) {
        auto canonical = canonicalEntryId(entry);
        auto found = remoteById.find(canonical.id);
        remoteById[canonical.id] = found == remoteById.end()
            ? canonical
            : pickDuplicateEntry(found->second, canonical);
    }
    int conflicts = 0;
    for (const auto& localEntry : local) {
        auto canonicalLocal = canonicalEntryId(localEntry);
        auto found = remoteById.find(canonicalLocal.id);
        if (found == remoteById.end()) {
            merged.push_back(canonicalLocal);
            continue;
        }
        const auto remoteEntry = found->second;
        remoteById.erase(found);
        auto comparison = compareVersion(effectiveVersion(canonicalLocal), effectiveVersion(remoteEntry));
        if (comparison == "localDominates") merged.push_back(canonicalLocal);
        else if (comparison == "remoteDominates") merged.push_back(remoteEntry);
        else if (comparison == "equal") merged.push_back(pickLatest(canonicalLocal, remoteEntry));
        else {
            ++conflicts;
            const VaultEntry& primary = strategy == "remoteWins" ? remoteEntry : canonicalLocal;
            const VaultEntry& secondary = strategy == "remoteWins" ? canonicalLocal : remoteEntry;
            merged.push_back(primary);
            merged.push_back(conflictCopy(secondary));
        }
    }
    for (const auto& [_, entry] : remoteById) merged.push_back(entry);
    int deletes = static_cast<int>(std::count_if(merged.begin(), merged.end(), [](const auto& entry) { return entry.isDeleted; }));
    return SyncMergeResult{merged, SyncMergeStats{static_cast<int>(merged.size()), conflicts, deletes}};
}

} // namespace pm
