#include "vault_core.hpp"

#include <algorithm>
#include <cctype>
#include <cstring>
#include <fstream>
#include <iomanip>
#include <openssl/evp.h>
#include <openssl/hmac.h>
#include <openssl/rand.h>
#include <openssl/sha.h>
#include <set>
#include <sstream>
#include <stdexcept>
#include <utility>
#include <vector>

namespace pm {
namespace {

std::vector<std::uint8_t> randomBytes(std::size_t count) {
    std::vector<std::uint8_t> bytes(count);
    if (RAND_bytes(bytes.data(), static_cast<int>(bytes.size())) != 1) {
        throw std::runtime_error("Secure random generation failed.");
    }
    return bytes;
}

bool parseIsoTimestamp(const std::string& value, std::time_t& output) {
    if (value.empty()) return false;
    std::tm tm{};
    std::istringstream in(value);
    in >> std::get_time(&tm, "%Y-%m-%dT%H:%M:%SZ");
    if (in.fail()) return false;
#if defined(_WIN32)
    output = _mkgmtime(&tm);
#else
    output = timegm(&tm);
#endif
    return true;
}

bool isTimestampAtLeast(const std::string& left, const std::string& right) {
    std::time_t leftTime = 0;
    std::time_t rightTime = 0;
    if (parseIsoTimestamp(left, leftTime) && parseIsoTimestamp(right, rightTime)) {
        return leftTime >= rightTime;
    }
    return left >= right;
}

bool constantTimeEqual(const std::vector<std::uint8_t>& left, const std::vector<std::uint8_t>& right) {
    if (left.size() != right.size()) return false;
    std::uint8_t diff = 0;
    for (std::size_t index = 0; index < left.size(); ++index) {
        diff |= left[index] ^ right[index];
    }
    return diff == 0;
}

struct SearchTerm {
    std::string field;
    std::string value;
};

std::string lowerCopy(std::string value) {
    std::transform(value.begin(), value.end(), value.begin(), [](unsigned char ch) {
        return static_cast<char>(std::tolower(ch));
    });
    return value;
}

std::string compactSearchKey(const std::string& value) {
    std::string key;
    for (char raw : value) {
        unsigned char ch = static_cast<unsigned char>(raw);
        if (std::isalnum(ch)) key.push_back(static_cast<char>(std::tolower(ch)));
    }
    return key;
}

std::string canonicalSearchField(const std::string& raw) {
    const auto key = compactSearchKey(raw);
    if (key == "title" || key == "label" || key == "name") return "label";
    if (key == "type" || key == "kind") return "type";
    if (key == "category" || key == "cat") return "category";
    if (key == "tag" || key == "tags") return "tag";
    if (key == "user" || key == "username" || key == "login") return "username";
    if (key == "password" || key == "pass" || key == "pwd" || key == "secret") return "secret";
    if (key == "note" || key == "notes") return "notes";
    if (key == "ip" || key == "ipaddress") return "ip";
    if (key == "address" || key == "addr" || key == "host" || key == "url") return "address";
    if (key == "app" || key == "appid" || key == "application") return "app";
    if (key == "server" || key == "servers" || key == "srv") return "server";
    if (key == "service" || key == "svc") return "service";
    if (key == "port") return "port";
    return key;
}

std::vector<SearchTerm> parseSearchTerms(const std::string& query) {
    std::vector<SearchTerm> terms;
    std::string token;
    auto flush = [&]() {
        if (token.empty()) return;
        if (token.size() > 1 && token[0] == '#') {
            terms.push_back({"tag", lowerCopy(token.substr(1))});
            token.clear();
            return;
        }
        const auto split = token.find(':');
        if (split != std::string::npos && split > 0 && split + 1 < token.size()) {
            const auto rawField = lowerCopy(token.substr(0, split));
            if (rawField == "http" || rawField == "https") {
                terms.push_back({"", lowerCopy(token)});
            } else {
                terms.push_back({canonicalSearchField(token.substr(0, split)), lowerCopy(token.substr(split + 1))});
            }
        } else {
            terms.push_back({"", lowerCopy(token)});
        }
        token.clear();
    };
    for (char ch : query) {
        if (std::isspace(static_cast<unsigned char>(ch)) || ch == ',') {
            flush();
        } else {
            token.push_back(ch);
        }
    }
    flush();
    return terms;
}

bool containsValue(const std::vector<std::string>& values, const std::string& needle) {
    for (const auto& value : values) {
        if (lowerCopy(value).find(needle) != std::string::npos) return true;
    }
    return false;
}

bool notesContainKeyValue(const VaultEntry& entry, const std::string& field, const std::string& value) {
    const auto notes = lowerCopy(entry.notes);
    return notes.find(field + ":" + value) != std::string::npos ||
        notes.find(field + "=" + value) != std::string::npos;
}

std::vector<std::string> searchValuesFor(const VaultEntry& entry, const std::string& field) {
    if (field.empty()) {
        std::vector<std::string> values{entry.label, entry.type, entry.username, entry.category, entry.notes};
        values.insert(values.end(), entry.tags.begin(), entry.tags.end());
        for (const auto& customField : entry.customFields) {
            values.push_back(customField.name);
            values.push_back(customField.value);
        }
        return values;
    }
    if (field == "label") return {entry.label};
    if (field == "type") return {entry.type};
    if (field == "category") return {entry.category};
    if (field == "tag") return entry.tags;
    if (field == "username") return {entry.username};
    if (field == "secret") return {entry.secret};
    if (field == "notes") return {entry.notes};
    std::vector<std::string> customValues;
    for (const auto& customField : entry.customFields) {
        const auto key = compactSearchKey(customField.name);
        if (!key.empty() && (key == field || key.find(field) != std::string::npos || field.find(key) != std::string::npos)) {
            customValues.push_back(customField.name);
            customValues.push_back(customField.value);
        }
    }
    if (!customValues.empty()) return customValues;
    return {};
}

bool matchesSearchTerm(const VaultEntry& entry, const SearchTerm& term) {
    if (containsValue(searchValuesFor(entry, term.field), term.value)) return true;
    return !term.field.empty() && notesContainKeyValue(entry, term.field, term.value);
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

std::string jsonString(const std::string& value) {
    return "\"" + escapeJson(value) + "\"";
}

std::string jsonStringArray(const std::vector<std::string>& values) {
    std::ostringstream out;
    out << "[";
    for (std::size_t index = 0; index < values.size(); ++index) {
        if (index > 0) out << ",";
        out << jsonString(values[index]);
    }
    out << "]";
    return out.str();
}

std::string syncPayloadJson(const VaultSyncPayload& payload) {
    const auto exportedAt = payload.exportedAt.empty() ? isoTimestamp() : payload.exportedAt;
    auto snapshot = payload.snapshot;
    if (snapshot.updatedAt.empty()) snapshot.updatedAt = exportedAt;
    std::ostringstream out;
    out << "{\"version\":" << payload.version
        << ",\"exportedAt\":" << jsonString(exportedAt)
        << ",\"deviceId\":" << jsonString(payload.deviceId)
        << ",\"revision\":" << payload.revision
        << ",\"snapshot\":" << serializeSnapshotJson(snapshot)
        << "}";
    return out.str();
}

class JsonReader {
public:
    explicit JsonReader(std::string source) : source_(std::move(source)) {}

    void objectStart() {
        skipWhitespace();
        require('{');
    }

    bool objectEnd() {
        skipWhitespace();
        if (peek() != '}') return false;
        ++position_;
        return true;
    }

    void arrayStart() {
        skipWhitespace();
        require('[');
    }

    bool arrayEnd() {
        skipWhitespace();
        if (peek() != ']') return false;
        ++position_;
        return true;
    }

    bool commaIfPresent() {
        skipWhitespace();
        if (peek() != ',') return false;
        ++position_;
        return true;
    }

    std::string key() {
        auto value = string();
        skipWhitespace();
        require(':');
        return value;
    }

    std::string string() {
        skipWhitespace();
        require('"');
        std::string output;
        while (position_ < source_.size()) {
            char ch = source_[position_++];
            if (ch == '"') return output;
            if (ch != '\\') {
                output.push_back(ch);
                continue;
            }
            if (position_ >= source_.size()) throw std::runtime_error("Invalid JSON escape.");
            const char escaped = source_[position_++];
            switch (escaped) {
                case '"': output.push_back('"'); break;
                case '\\': output.push_back('\\'); break;
                case '/': output.push_back('/'); break;
                case 'b': output.push_back('\b'); break;
                case 'f': output.push_back('\f'); break;
                case 'n': output.push_back('\n'); break;
                case 'r': output.push_back('\r'); break;
                case 't': output.push_back('\t'); break;
                default: throw std::runtime_error("Unsupported JSON escape.");
            }
        }
        throw std::runtime_error("Unterminated JSON string.");
    }

    std::string nullableString() {
        skipWhitespace();
        if (source_.compare(position_, 4, "null") == 0) {
            position_ += 4;
            return "";
        }
        return string();
    }

    bool boolean() {
        skipWhitespace();
        if (source_.compare(position_, 4, "true") == 0) {
            position_ += 4;
            return true;
        }
        if (source_.compare(position_, 5, "false") == 0) {
            position_ += 5;
            return false;
        }
        throw std::runtime_error("Expected JSON boolean.");
    }

    int integer() {
        skipWhitespace();
        std::size_t end = position_;
        if (end < source_.size() && source_[end] == '-') ++end;
        while (end < source_.size() && std::isdigit(static_cast<unsigned char>(source_[end]))) ++end;
        if (end == position_) throw std::runtime_error("Expected JSON integer.");
        int value = std::stoi(source_.substr(position_, end - position_));
        position_ = end;
        return value;
    }

    std::string rawValue() {
        skipWhitespace();
        const auto start = position_;
        skipValue();
        return source_.substr(start, position_ - start);
    }

    void skipValue() {
        skipWhitespace();
        const char ch = peek();
        if (ch == '"') {
            (void)string();
        } else if (ch == '{') {
            objectStart();
            if (!objectEnd()) {
                do {
                    (void)key();
                    skipValue();
                } while (commaIfPresent());
                if (!objectEnd()) throw std::runtime_error("Expected JSON object end.");
            }
        } else if (ch == '[') {
            arrayStart();
            if (!arrayEnd()) {
                do {
                    skipValue();
                } while (commaIfPresent());
                if (!arrayEnd()) throw std::runtime_error("Expected JSON array end.");
            }
        } else if (ch == 't' || ch == 'f') {
            (void)boolean();
        } else if (source_.compare(position_, 4, "null") == 0) {
            position_ += 4;
        } else {
            (void)integer();
        }
    }

private:
    char peek() {
        skipWhitespace();
        if (position_ >= source_.size()) return '\0';
        return source_[position_];
    }

    void require(char expected) {
        if (position_ >= source_.size() || source_[position_] != expected) {
            throw std::runtime_error("Invalid JSON.");
        }
        ++position_;
    }

    void skipWhitespace() {
        while (position_ < source_.size() && std::isspace(static_cast<unsigned char>(source_[position_]))) ++position_;
    }

    std::string source_;
    std::size_t position_ = 0;
};

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

std::string stableFieldId(const std::string& name) {
    std::string slug;
    bool previousWasSeparator = false;
    for (char raw : trimCopy(name)) {
        const auto ch = static_cast<unsigned char>(raw);
        if (std::isalnum(ch)) {
            slug.push_back(static_cast<char>(std::tolower(ch)));
            previousWasSeparator = false;
        } else if (!previousWasSeparator) {
            slug.push_back('-');
            previousWasSeparator = true;
        }
    }
    while (!slug.empty() && slug.front() == '-') slug.erase(slug.begin());
    while (!slug.empty() && slug.back() == '-') slug.pop_back();
    return "template-" + (slug.empty() ? canonicalIdString(name) : slug);
}

FieldTemplate makeFieldTemplate(const std::string& name) {
    const auto clean = trimCopy(name);
    return FieldTemplate{stableFieldId(clean), clean};
}

std::vector<FieldTemplate> normalizeFieldTemplates(const std::vector<FieldTemplate>& fields) {
    std::vector<FieldTemplate> normalized;
    std::set<std::string> seen;
    for (const auto& field : fields) {
        const auto cleanName = trimCopy(field.name);
        if (cleanName.empty()) continue;
        const auto key = lowerCopy(cleanName);
        if (!seen.insert(key).second) continue;
        normalized.push_back(FieldTemplate{field.id.empty() ? stableFieldId(cleanName) : field.id, cleanName});
    }
    return normalized;
}

std::vector<FieldTemplate> fieldsFromNames(const std::vector<std::string>& names) {
    std::vector<FieldTemplate> fields;
    for (const auto& name : names) fields.push_back(makeFieldTemplate(name));
    return fields;
}

void upsertCategoryTemplate(VaultSnapshot& snapshot, const std::string& category, const std::vector<FieldTemplate>& fields) {
    const auto clean = trimCopy(category);
    const auto categoryKey = lowerCopy(clean);
    const auto normalizedFields = normalizeFieldTemplates(fields.empty() ? defaultCategoryFields() : fields);
    for (auto& templateEntry : snapshot.categoryTemplates) {
        if (lowerCopy(trimCopy(templateEntry.category)) == categoryKey) {
            templateEntry.category = clean;
            templateEntry.fields = normalizedFields;
            return;
        }
    }
    snapshot.categoryTemplates.push_back(CategoryTemplate{clean, normalizedFields});
    std::sort(snapshot.categoryTemplates.begin(), snapshot.categoryTemplates.end(), [](const auto& left, const auto& right) {
        return left.category < right.category;
    });
}

std::vector<std::string> readStringArray(JsonReader& reader) {
    std::vector<std::string> values;
    reader.arrayStart();
    if (!reader.arrayEnd()) {
        do {
            values.push_back(reader.string());
        } while (reader.commaIfPresent());
        if (!reader.arrayEnd()) throw std::runtime_error("Expected JSON array end.");
    }
    return values;
}

std::map<std::string, int> readIntMap(JsonReader& reader) {
    std::map<std::string, int> values;
    reader.objectStart();
    if (!reader.objectEnd()) {
        do {
            const auto key = reader.key();
            values[key] = reader.integer();
        } while (reader.commaIfPresent());
        if (!reader.objectEnd()) throw std::runtime_error("Expected JSON object end.");
    }
    return values;
}

CustomField readCustomField(JsonReader& reader) {
    CustomField field;
    reader.objectStart();
    if (!reader.objectEnd()) {
        do {
            const auto key = reader.key();
            if (key == "id") {
                field.id = reader.string();
            } else if (key == "name") {
                field.name = reader.string();
            } else if (key == "value") {
                field.value = reader.string();
            } else {
                reader.skipValue();
            }
        } while (reader.commaIfPresent());
        if (!reader.objectEnd()) throw std::runtime_error("Expected JSON object end.");
    }
    if (field.id.empty()) field.id = randomId();
    return field;
}

std::vector<CustomField> readCustomFieldArray(JsonReader& reader) {
    std::vector<CustomField> fields;
    reader.arrayStart();
    if (!reader.arrayEnd()) {
        do {
            fields.push_back(readCustomField(reader));
        } while (reader.commaIfPresent());
        if (!reader.arrayEnd()) throw std::runtime_error("Expected JSON array end.");
    }
    return fields;
}

void readServiceAccount(JsonReader& reader, VaultEntry& entry) {
    reader.objectStart();
    if (!reader.objectEnd()) {
        do {
            const auto key = reader.key();
            if (key == "username" && entry.username.empty()) {
                entry.username = reader.string();
            } else if (key == "password" && entry.secret.empty()) {
                entry.secret = reader.string();
            } else {
                reader.skipValue();
            }
        } while (reader.commaIfPresent());
        if (!reader.objectEnd()) throw std::runtime_error("Expected JSON object end.");
    }
}

void readServiceAccountArray(JsonReader& reader, VaultEntry& entry) {
    reader.arrayStart();
    if (!reader.arrayEnd()) {
        do {
            readServiceAccount(reader, entry);
        } while (reader.commaIfPresent());
        if (!reader.arrayEnd()) throw std::runtime_error("Expected JSON array end.");
    }
}

std::string customFieldsJson(const std::vector<CustomField>& fields) {
    std::ostringstream out;
    out << "[";
    for (std::size_t index = 0; index < fields.size(); ++index) {
        if (index > 0) out << ",";
        const auto& field = fields[index];
        out << "{\"id\":" << jsonString(canonicalIdString(field.id))
            << ",\"name\":" << jsonString(field.name)
            << ",\"value\":" << jsonString(field.value) << "}";
    }
    out << "]";
    return out.str();
}

std::string syncResultMessage(const SyncMergeStats& stats, int revision) {
    std::ostringstream out;
    out << "Synced " << stats.total << " items, " << stats.conflicts
        << " conflicts, " << stats.deletes << " deletes, revision " << revision << ".";
    return out.str();
}

std::vector<std::string> mergeTaxonomyValues(std::vector<std::string> values) {
    std::set<std::string> seen;
    std::vector<std::string> merged;
    for (const auto& value : values) {
        const auto clean = trimCopy(value);
        if (clean.empty()) continue;
        const auto key = lowerCopy(clean);
        if (seen.insert(key).second) merged.push_back(clean);
    }
    std::sort(merged.begin(), merged.end());
    return merged;
}

std::vector<CategoryTemplate> mergeCategoryTemplatesForSync(
    const std::vector<CategoryTemplate>& base,
    const std::vector<CategoryTemplate>& local,
    const std::vector<CategoryTemplate>& remote,
    const std::vector<std::string>& categories
) {
    std::set<std::string> categoryKeys;
    for (const auto& category : categories) categoryKeys.insert(lowerCopy(trimCopy(category)));
    std::map<std::string, CategoryTemplate> templatesByCategory;
    auto insert = [&](const CategoryTemplate& templateEntry) {
        const auto category = trimCopy(templateEntry.category);
        const auto key = lowerCopy(category);
        if (category.empty() || categoryKeys.count(key) == 0 || templatesByCategory.count(key) > 0) return;
        templatesByCategory[key] = CategoryTemplate{category, normalizeFieldTemplates(templateEntry.fields)};
    };
    for (const auto& templateEntry : base) insert(templateEntry);
    for (const auto& templateEntry : local) insert(templateEntry);
    for (const auto& templateEntry : remote) insert(templateEntry);
    std::vector<CategoryTemplate> result;
    for (const auto& category : categories) {
        const auto found = templatesByCategory.find(lowerCopy(trimCopy(category)));
        if (found != templatesByCategory.end()) result.push_back(found->second);
    }
    return result;
}

VaultSnapshot mergeSnapshotsForSync(
    const VaultSnapshot& local,
    const VaultSnapshot& remote,
    const std::vector<VaultEntry>& entries,
    bool localHasChanges
) {
    VaultSnapshot merged;
    merged.entries = entries;
    std::sort(merged.entries.begin(), merged.entries.end(), [](const auto& left, const auto& right) {
        return left.updatedAt > right.updatedAt;
    });
    std::vector<std::string> values = localHasChanges ? local.categories : remote.categories;
    const auto baseTemplates = localHasChanges ? local.categoryTemplates : remote.categoryTemplates;
    for (const auto& templateEntry : baseTemplates) values.push_back(templateEntry.category);
    for (const auto& entry : merged.entries) {
        if (!entry.isDeleted) values.push_back(entry.category);
    }
    merged.categories = mergeTaxonomyValues(values);
    values = localHasChanges ? local.tags : remote.tags;
    for (const auto& entry : merged.entries) {
        if (!entry.isDeleted) values.insert(values.end(), entry.tags.begin(), entry.tags.end());
    }
    merged.tags = mergeTaxonomyValues(values);
    merged.categoryTemplates = mergeCategoryTemplatesForSync(baseTemplates, local.categoryTemplates, remote.categoryTemplates, merged.categories);
    const auto& latestSnapshot = isTimestampAtLeast(local.updatedAt, remote.updatedAt) ? local : remote;
    merged.requireTotp = latestSnapshot.requireTotp;
    merged.totpSecret = latestSnapshot.totpSecret;
    merged.syncStatus = latestSnapshot.syncStatus;
    merged.backupStatus = latestSnapshot.backupStatus;
    merged.updatedAt = isTimestampAtLeast(local.updatedAt, remote.updatedAt) ? local.updatedAt : remote.updatedAt;
    return merged;
}

bool snapshotsEquivalent(const VaultSnapshot& left, const VaultSnapshot& right) {
    auto normalizedLeft = left;
    auto normalizedRight = right;
    if (normalizedLeft.updatedAt.empty()) normalizedLeft.updatedAt = "__empty__";
    if (normalizedRight.updatedAt.empty()) normalizedRight.updatedAt = "__empty__";
    return serializeSnapshotJson(normalizedLeft) == serializeSnapshotJson(normalizedRight);
}

std::string versionJson(const std::map<std::string, int>& version) {
    std::ostringstream out;
    out << "{";
    bool first = true;
    for (const auto& [device, count] : version) {
        if (!first) out << ",";
        first = false;
        out << jsonString(device) << ":" << count;
    }
    out << "}";
    return out.str();
}

void readEntryPayloadObject(JsonReader& reader, VaultEntry& entry, const std::string& payloadType) {
    reader.objectStart();
    if (!reader.objectEnd()) {
        do {
            const auto key = reader.key();
            if (key == "category") {
                entry.category = reader.string();
            } else if (key == "tags") {
                entry.tags = readStringArray(reader);
            } else if (key == "notes") {
                entry.notes = reader.string();
            } else if (key == "username") {
                entry.username = reader.string();
            } else if (key == "password") {
                entry.secret = reader.string();
            } else if (key == "secretKey") {
                const auto value = reader.string();
                if (entry.secret.empty()) entry.secret = value;
            } else if (key == "accounts") {
                readServiceAccountArray(reader, entry);
            } else if (key == "ipAddress" && entry.notes.find("ipAddress:") == std::string::npos) {
                const auto value = reader.string();
                if (!value.empty()) entry.notes += (entry.notes.empty() ? "" : " ") + std::string("ipAddress:") + value;
            } else if (key == "port" && entry.notes.find("port:") == std::string::npos) {
                const auto value = reader.string();
                if (!value.empty()) entry.notes += (entry.notes.empty() ? "" : " ") + std::string("port:") + value;
            } else if (key == "connectionAddress" && entry.notes.find("connectionAddress:") == std::string::npos) {
                const auto value = reader.string();
                if (!value.empty()) entry.notes += (entry.notes.empty() ? "" : " ") + std::string("connectionAddress:") + value;
            } else if (key == "connectionPort" && entry.notes.find("connectionPort:") == std::string::npos) {
                const auto value = reader.string();
                if (!value.empty()) entry.notes += (entry.notes.empty() ? "" : " ") + std::string("connectionPort:") + value;
            } else {
                reader.skipValue();
            }
        } while (reader.commaIfPresent());
        if (!reader.objectEnd()) throw std::runtime_error("Expected JSON object end.");
    }
    if (entry.type.empty() && !payloadType.empty()) entry.type = payloadType;
}

void hydrateEntryFromPayload(VaultEntry& entry) {
    if (entry.payloadJson.empty()) return;
    try {
        JsonReader reader(entry.payloadJson);
        reader.objectStart();
        if (!reader.objectEnd()) {
            do {
                const auto key = reader.key();
                if (key == "credential" || key == "server" || key == "service") {
                    readEntryPayloadObject(reader, entry, key);
                } else {
                    reader.skipValue();
                }
            } while (reader.commaIfPresent());
            if (!reader.objectEnd()) throw std::runtime_error("Expected JSON object end.");
        }
    } catch (const std::exception&) {
        // Keep the original payload bytes even if lightweight hydration fails.
    }
}

std::string payloadJsonFor(const VaultEntry& entry) {
    const auto type = entry.type.empty() ? "credential" : entry.type;
    std::ostringstream payload;
    payload << "{\"" << escapeJson(type) << "\":{";
    if (type == "server") {
        payload << "\"name\":" << jsonString(entry.label)
                << ",\"ipAddress\":\"\",\"port\":\"\",\"username\":" << jsonString(entry.username)
                << ",\"password\":" << jsonString(entry.secret)
                << ",\"accounts\":[],\"basicConfig\":\"\",\"operatingSystem\":\"\",\"location\":\"\"";
    } else if (type == "service") {
        payload << "\"name\":" << jsonString(entry.label)
                << ",\"connectionAddress\":\"\",\"connectionPort\":\"\",\"accountId\":null,\"serverIds\":[],\"accounts\":[";
        if (!entry.username.empty() || !entry.secret.empty()) {
            payload << "{\"username\":" << jsonString(entry.username)
                    << ",\"password\":" << jsonString(entry.secret)
                    << ",\"note\":\"\"}";
        }
        payload << "]";
    } else {
        payload << "\"username\":" << jsonString(entry.username)
                << ",\"password\":" << jsonString(entry.secret)
                << ",\"accounts\":[],\"token\":\"\",\"appId\":\"\",\"accessKey\":\"\",\"secretKey\":\"\"";
    }
    payload << ",\"notes\":" << jsonString(entry.notes)
            << ",\"tags\":" << jsonStringArray(entry.tags)
            << ",\"category\":" << jsonString(entry.category)
            << "}}";
    return payload.str();
}

std::string entryPayloadJson(const VaultEntry& entry) {
    return entry.payloadJson.empty() ? payloadJsonFor(entry) : entry.payloadJson;
}

std::string entryJson(const VaultEntry& entry) {
    const auto now = isoTimestamp();
    std::ostringstream out;
    out << "{\"id\":" << jsonString(canonicalIdString(entry.id))
        << ",\"label\":" << jsonString(entry.label)
        << ",\"type\":" << jsonString(entry.type.empty() ? "credential" : entry.type)
        << ",\"payload\":" << entryPayloadJson(entry)
        << ",\"customFields\":" << customFieldsJson(entry.customFields)
        << ",\"createdAt\":" << jsonString(entry.createdAt.empty() ? now : entry.createdAt)
        << ",\"updatedAt\":" << jsonString(entry.updatedAt.empty() ? now : entry.updatedAt)
        << ",\"version\":" << versionJson(entry.version)
        << ",\"updatedBy\":" << jsonString(entry.updatedBy.empty() ? "native-cli" : entry.updatedBy)
        << ",\"isDeleted\":" << (entry.isDeleted ? "true" : "false")
        << ",\"deletedAt\":";
    if (entry.deletedAt.empty()) {
        out << "null";
    } else {
        out << jsonString(entry.deletedAt);
    }
    out << "}";
    return out.str();
}

FieldTemplate readFieldTemplate(JsonReader& reader) {
    FieldTemplate field;
    reader.objectStart();
    if (!reader.objectEnd()) {
        do {
            const auto key = reader.key();
            if (key == "id") {
                field.id = reader.string();
            } else if (key == "name") {
                field.name = reader.string();
            } else {
                reader.skipValue();
            }
        } while (reader.commaIfPresent());
        if (!reader.objectEnd()) throw std::runtime_error("Expected JSON object end.");
    }
    return field;
}

std::vector<FieldTemplate> readFieldTemplateArray(JsonReader& reader) {
    std::vector<FieldTemplate> fields;
    reader.arrayStart();
    if (!reader.arrayEnd()) {
        do {
            fields.push_back(readFieldTemplate(reader));
        } while (reader.commaIfPresent());
        if (!reader.arrayEnd()) throw std::runtime_error("Expected JSON array end.");
    }
    return normalizeFieldTemplates(fields);
}

CategoryTemplate readCategoryTemplate(JsonReader& reader) {
    CategoryTemplate templateEntry;
    reader.objectStart();
    if (!reader.objectEnd()) {
        do {
            const auto key = reader.key();
            if (key == "category") {
                templateEntry.category = reader.string();
            } else if (key == "fields") {
                templateEntry.fields = readFieldTemplateArray(reader);
            } else {
                reader.skipValue();
            }
        } while (reader.commaIfPresent());
        if (!reader.objectEnd()) throw std::runtime_error("Expected JSON object end.");
    }
    if (templateEntry.fields.empty()) templateEntry.fields = defaultCategoryFields();
    return templateEntry;
}

std::vector<CategoryTemplate> readCategoryTemplateArray(JsonReader& reader) {
    std::vector<CategoryTemplate> templates;
    reader.arrayStart();
    if (!reader.arrayEnd()) {
        do {
            auto templateEntry = readCategoryTemplate(reader);
            if (!trimCopy(templateEntry.category).empty()) templates.push_back(templateEntry);
        } while (reader.commaIfPresent());
        if (!reader.arrayEnd()) throw std::runtime_error("Expected JSON array end.");
    }
    return templates;
}

VaultEntry readVaultEntry(JsonReader& reader) {
    VaultEntry entry;
    reader.objectStart();
    if (!reader.objectEnd()) {
        do {
            const auto key = reader.key();
            if (key == "id") {
                entry.id = reader.string();
            } else if (key == "label") {
                entry.label = reader.string();
            } else if (key == "type") {
                entry.type = reader.string();
            } else if (key == "username") {
                entry.username = reader.string();
            } else if (key == "secret") {
                entry.secret = reader.string();
            } else if (key == "category") {
                entry.category = reader.string();
            } else if (key == "notes") {
                entry.notes = reader.string();
            } else if (key == "tags") {
                entry.tags = readStringArray(reader);
            } else if (key == "payload") {
                entry.payloadJson = reader.rawValue();
            } else if (key == "customFields") {
                entry.customFields = readCustomFieldArray(reader);
            } else if (key == "version") {
                entry.version = readIntMap(reader);
            } else if (key == "updatedBy") {
                entry.updatedBy = reader.string();
            } else if (key == "createdAt") {
                entry.createdAt = reader.string();
            } else if (key == "updatedAt") {
                entry.updatedAt = reader.string();
            } else if (key == "deletedAt") {
                entry.deletedAt = reader.nullableString();
            } else if (key == "isDeleted") {
                entry.isDeleted = reader.boolean();
            } else {
                reader.skipValue();
            }
        } while (reader.commaIfPresent());
        if (!reader.objectEnd()) throw std::runtime_error("Expected JSON object end.");
    }
    entry.id = canonicalIdString(entry.id);
    return entry;
}

std::vector<VaultEntry> readVaultEntryArray(JsonReader& reader) {
    std::vector<VaultEntry> entries;
    reader.arrayStart();
    if (!reader.arrayEnd()) {
        do {
            auto entry = readVaultEntry(reader);
            hydrateEntryFromPayload(entry);
            entries.push_back(entry);
        } while (reader.commaIfPresent());
        if (!reader.arrayEnd()) throw std::runtime_error("Expected JSON array end.");
    }
    return entries;
}

void readSecuritySettings(JsonReader& reader, VaultSnapshot& snapshot) {
    reader.objectStart();
    if (!reader.objectEnd()) {
        do {
            const auto key = reader.key();
            if (key == "requireTotp") {
                snapshot.requireTotp = reader.boolean();
            } else if (key == "totpSecret") {
                snapshot.totpSecret = reader.string();
            } else {
                reader.skipValue();
            }
        } while (reader.commaIfPresent());
        if (!reader.objectEnd()) throw std::runtime_error("Expected JSON object end.");
    }
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

std::string defaultObjectKey(const std::string& objectKey) {
    const auto trimmed = trimCopy(objectKey);
    return trimmed.empty() ? "vault.sync.json" : trimmed;
}

std::string trimTrailingSlash(std::string value) {
    while (!value.empty() && value.back() == '/') value.pop_back();
    return value;
}

std::string trimLeadingSlash(std::string value) {
    while (!value.empty() && value.front() == '/') value.erase(value.begin());
    return value;
}

std::string normalizeEndpointUrl(const std::string& value) {
    const auto trimmed = trimCopy(value);
    if (trimmed.rfind("http://", 0) == 0 || trimmed.rfind("https://", 0) == 0) return trimmed;
    return "https://" + trimmed;
}

std::string joinUrlPath(const std::string& base, const std::string& path) {
    const auto trimmedBase = trimTrailingSlash(trimCopy(base));
    const auto trimmedPath = trimLeadingSlash(trimCopy(path));
    if (trimmedBase.empty()) return trimmedPath;
    if (trimmedPath.empty()) return trimmedBase;
    return trimmedBase + "/" + trimmedPath;
}

bool requiresObjectStoreCredentials(ObjectSyncProvider provider) {
    return provider == ObjectSyncProvider::TencentCos || provider == ObjectSyncProvider::AliyunOss;
}

void requireObjectStoreCredentials(const ObjectSyncConfig& config) {
    if (!requiresObjectStoreCredentials(config.provider)) return;
    if (trimCopy(config.accessKeyId).empty()) throw std::runtime_error("Object sync accessKeyId is required.");
    if (trimCopy(config.secretAccessKey).empty()) throw std::runtime_error("Object sync secretAccessKey is required.");
    if (trimCopy(config.bucket).empty()) throw std::runtime_error("Object sync bucket is required.");
}

std::string buildObjectSyncBaseUrl(const ObjectSyncConfig& config) {
    const auto customUrl = trimCopy(config.customUrl);
    if (!customUrl.empty()) return trimTrailingSlash(customUrl);

    const auto endpoint = trimCopy(config.endpoint);
    if (endpoint.empty()) throw std::runtime_error("Object sync endpoint or customUrl is required.");

    if (config.provider == ObjectSyncProvider::TencentCos || config.provider == ObjectSyncProvider::AliyunOss) {
        auto bucket = trimCopy(config.bucket);
        const auto appId = trimCopy(config.appId);
        const auto hasAppIdSuffix = bucket.size() >= appId.size() + 1 &&
            bucket.compare(bucket.size() - appId.size() - 1, appId.size() + 1, "-" + appId) == 0;
        if (config.provider == ObjectSyncProvider::TencentCos && !appId.empty() && !hasAppIdSuffix) {
            bucket += "-" + appId;
        }
        auto normalizedEndpoint = trimTrailingSlash(normalizeEndpointUrl(endpoint));
        const auto schemeEnd = normalizedEndpoint.find("://");
        const auto hostStart = schemeEnd == std::string::npos ? 0 : schemeEnd + 3;
        if (normalizedEndpoint.compare(hostStart, bucket.size() + 1, bucket + ".") == 0) {
            return normalizedEndpoint;
        }
        return normalizedEndpoint.substr(0, hostStart) + bucket + "." + normalizedEndpoint.substr(hostStart);
    }
    return trimTrailingSlash(endpoint);
}

std::string upperCopy(std::string value) {
    std::transform(value.begin(), value.end(), value.begin(), [](unsigned char ch) {
        return static_cast<char>(std::toupper(ch));
    });
    return value;
}

std::string hexEncode(const unsigned char* bytes, unsigned int length) {
    std::ostringstream out;
    for (unsigned int index = 0; index < length; ++index) {
        out << std::hex << std::setw(2) << std::setfill('0') << static_cast<int>(bytes[index]);
    }
    return out.str();
}

std::string sha1Hex(const std::string& value) {
    unsigned char digest[SHA_DIGEST_LENGTH]{};
    SHA1(reinterpret_cast<const unsigned char*>(value.data()), value.size(), digest);
    return hexEncode(digest, SHA_DIGEST_LENGTH);
}

std::string sha256Hex(const std::string& value) {
    unsigned char digest[SHA256_DIGEST_LENGTH]{};
    SHA256(reinterpret_cast<const unsigned char*>(value.data()), value.size(), digest);
    return hexEncode(digest, SHA256_DIGEST_LENGTH);
}

std::vector<std::uint8_t> hmacBytes(const EVP_MD* digest, const std::vector<std::uint8_t>& key, const std::string& value) {
    unsigned int length = 0;
    unsigned char output[EVP_MAX_MD_SIZE]{};
    HMAC(
        digest,
        key.data(),
        static_cast<int>(key.size()),
        reinterpret_cast<const unsigned char*>(value.data()),
        value.size(),
        output,
        &length
    );
    return {output, output + length};
}

std::vector<std::uint8_t> hmacSha1Bytes(const std::vector<std::uint8_t>& key, const std::string& value) {
    return hmacBytes(EVP_sha1(), key, value);
}

std::vector<std::uint8_t> hmacSha256Bytes(const std::vector<std::uint8_t>& key, const std::string& value) {
    return hmacBytes(EVP_sha256(), key, value);
}

std::string hmacSha1Hex(const std::string& key, const std::string& value) {
    const auto bytes = hmacSha1Bytes({key.begin(), key.end()}, value);
    return hexEncode(bytes.data(), static_cast<unsigned int>(bytes.size()));
}

std::string hmacSha256Hex(const std::vector<std::uint8_t>& key, const std::string& value) {
    const auto bytes = hmacSha256Bytes(key, value);
    return hexEncode(bytes.data(), static_cast<unsigned int>(bytes.size()));
}

std::string percentEncode(const std::string& value) {
    std::ostringstream out;
    out << std::uppercase << std::hex;
    for (unsigned char ch : value) {
        if (std::isalnum(ch) || ch == '-' || ch == '_' || ch == '.' || ch == '~') {
            out << static_cast<char>(ch);
        } else {
            out << '%' << std::setw(2) << std::setfill('0') << static_cast<int>(ch);
        }
    }
    return out.str();
}

struct UrlParts {
    std::string scheme;
    std::string authority;
    std::string host;
    std::string path;
    std::string query;
};

UrlParts parseUrl(const std::string& url) {
    const auto schemeEnd = url.find("://");
    if (schemeEnd == std::string::npos) throw std::runtime_error("Object sync URL must include a scheme.");
    const auto authorityStart = schemeEnd + 3;
    auto pathStart = url.find('/', authorityStart);
    auto queryStart = url.find('?', authorityStart);
    const auto authorityEnd = std::min(
        pathStart == std::string::npos ? url.size() : pathStart,
        queryStart == std::string::npos ? url.size() : queryStart
    );
    UrlParts parts;
    parts.scheme = url.substr(0, schemeEnd);
    parts.authority = url.substr(authorityStart, authorityEnd - authorityStart);
    parts.host = lowerCopy(parts.authority.substr(0, parts.authority.find(':')));
    if (pathStart != std::string::npos && (queryStart == std::string::npos || pathStart < queryStart)) {
        parts.path = url.substr(pathStart, (queryStart == std::string::npos ? url.size() : queryStart) - pathStart);
    } else {
        parts.path = "/";
    }
    if (queryStart != std::string::npos) {
        parts.query = url.substr(queryStart + 1);
    }
    if (parts.authority.empty() || parts.host.empty()) throw std::runtime_error("Object sync URL host is required.");
    if (parts.path.empty()) parts.path = "/";
    return parts;
}

std::map<std::string, std::string> parseQuery(const std::string& query) {
    std::map<std::string, std::string> result;
    std::size_t start = 0;
    while (start < query.size()) {
        const auto end = query.find('&', start);
        const auto part = query.substr(start, end == std::string::npos ? std::string::npos : end - start);
        if (!part.empty()) {
            const auto split = part.find('=');
            const auto name = lowerCopy(split == std::string::npos ? part : part.substr(0, split));
            const auto value = split == std::string::npos ? "" : part.substr(split + 1);
            result[name] = value;
        }
        if (end == std::string::npos) break;
        start = end + 1;
    }
    return result;
}

std::string canonicalQuery(const std::string& query) {
    std::ostringstream out;
    bool first = true;
    for (const auto& [name, value] : parseQuery(query)) {
        if (!first) out << '&';
        first = false;
        out << percentEncode(name) << '=' << percentEncode(value);
    }
    return out.str();
}

std::string isoBasicTimestamp(std::time_t now) {
    std::tm tm{};
    gmtime_r(&now, &tm);
    std::ostringstream out;
    out << std::put_time(&tm, "%Y%m%dT%H%M%SZ");
    return out.str();
}

std::string aliyunRegionFromUrl(const ObjectSyncConfig& config, const UrlParts& url) {
    for (const auto& candidate : {config.endpoint, config.customUrl, url.host}) {
        const auto lower = lowerCopy(candidate);
        auto marker = lower.find("oss-");
        if (marker == std::string::npos) marker = lower.find("oss.");
        if (marker == std::string::npos) continue;
        const auto regionStart = marker + 4;
        const auto regionEnd = lower.find(".aliyuncs.com", regionStart);
        if (regionEnd != std::string::npos && regionEnd > regionStart) {
            return lower.substr(regionStart, regionEnd - regionStart);
        }
    }
    throw std::runtime_error("Alibaba Cloud OSS endpoint must include a region for OSS V4 signing.");
}

std::vector<std::uint8_t> aliyunSigningKey(const std::string& secret, const std::string& date, const std::string& region) {
    const std::string prefixedSecret = "aliyun_v4" + secret;
    auto dateKey = hmacSha256Bytes({prefixedSecret.begin(), prefixedSecret.end()}, date);
    const auto regionKey = hmacSha256Bytes(dateKey, region);
    const auto serviceKey = hmacSha256Bytes(regionKey, "oss");
    return hmacSha256Bytes(serviceKey, "aliyun_v4_request");
}

void applyTencentCosHeaders(ObjectSyncRequest& request, const ObjectSyncConfig& config, std::time_t now, const std::string& contentType) {
    const auto url = parseUrl(request.objectUrl);
    const auto signTime = std::to_string(now) + ";" + std::to_string(now + 900);
    std::map<std::string, std::string> signedHeaders{{"host", lowerCopy(url.authority)}};
    if (!contentType.empty()) signedHeaders["content-type"] = contentType;

    std::ostringstream headerString;
    bool firstHeader = true;
    for (const auto& [name, value] : signedHeaders) {
        if (!firstHeader) headerString << '&';
        firstHeader = false;
        headerString << percentEncode(name) << '=' << percentEncode(trimCopy(value));
    }

    std::ostringstream headerList;
    bool firstName = true;
    for (const auto& [name, _] : signedHeaders) {
        if (!firstName) headerList << ';';
        firstName = false;
        headerList << name;
    }

    std::ostringstream urlParamString;
    bool firstParam = true;
    for (const auto& [name, value] : parseQuery(url.query)) {
        if (!firstParam) urlParamString << '&';
        firstParam = false;
        urlParamString << percentEncode(name) << '=' << percentEncode(value);
    }

    std::ostringstream urlParamList;
    firstParam = true;
    for (const auto& [name, _] : parseQuery(url.query)) {
        if (!firstParam) urlParamList << ';';
        firstParam = false;
        urlParamList << name;
    }

    const auto httpString = lowerCopy(request.method) + "\n" + url.path + "\n" + urlParamString.str() + "\n" + headerString.str() + "\n";
    const auto stringToSign = "sha1\n" + signTime + "\n" + sha1Hex(httpString) + "\n";
    const auto signKey = hmacSha1Hex(config.secretAccessKey, signTime);
    const auto signature = hmacSha1Hex(signKey, stringToSign);
    request.headers["Host"] = lowerCopy(url.authority);
    if (!contentType.empty()) request.headers["Content-Type"] = contentType;
    request.headers["Authorization"] =
        "q-sign-algorithm=sha1&q-ak=" + percentEncode(config.accessKeyId) +
        "&q-sign-time=" + signTime +
        "&q-key-time=" + signTime +
        "&q-header-list=" + headerList.str() +
        "&q-url-param-list=" + urlParamList.str() +
        "&q-signature=" + signature;
}

void applyAliyunOssHeaders(ObjectSyncRequest& request, const ObjectSyncConfig& config, std::time_t now, const std::string& contentType) {
    const auto url = parseUrl(request.objectUrl);
    const auto timestamp = isoBasicTimestamp(now);
    const auto date = timestamp.substr(0, 8);
    const auto region = aliyunRegionFromUrl(config, url);
    const auto payloadHash = sha256Hex(request.body);
    std::map<std::string, std::string> signedHeaders{
        {"host", lowerCopy(url.authority)},
        {"x-oss-content-sha256", payloadHash},
        {"x-oss-date", timestamp},
    };
    if (!contentType.empty()) signedHeaders["content-type"] = contentType;

    std::ostringstream canonicalHeaders;
    std::ostringstream additionalHeaders;
    bool first = true;
    for (const auto& [name, value] : signedHeaders) {
        canonicalHeaders << name << ':' << trimCopy(value) << "\n";
        if (!first) additionalHeaders << ';';
        first = false;
        additionalHeaders << name;
    }

    const auto canonicalRequest = upperCopy(request.method) + "\n" +
        url.path + "\n" +
        canonicalQuery(url.query) + "\n" +
        canonicalHeaders.str() + "\n" +
        additionalHeaders.str() + "\n" +
        payloadHash;
    const auto scope = date + "/" + region + "/oss/aliyun_v4_request";
    const auto stringToSign = "OSS4-HMAC-SHA256\n" + timestamp + "\n" + scope + "\n" + sha256Hex(canonicalRequest);
    const auto signature = hmacSha256Hex(aliyunSigningKey(config.secretAccessKey, date, region), stringToSign);

    request.headers["Host"] = lowerCopy(url.authority);
    if (!contentType.empty()) request.headers["Content-Type"] = contentType;
    request.headers["x-oss-content-sha256"] = payloadHash;
    request.headers["x-oss-date"] = timestamp;
    request.headers["Authorization"] =
        "OSS4-HMAC-SHA256 Credential=" + percentEncode(config.accessKeyId) +
        "/" + scope +
        ",AdditionalHeaders=" + additionalHeaders.str() +
        ",Signature=" + signature;
}

} // namespace

std::string randomId() {
    auto bytes = randomBytes(16);
    bytes[6] = static_cast<std::uint8_t>((bytes[6] & 0x0f) | 0x40);
    bytes[8] = static_cast<std::uint8_t>((bytes[8] & 0x3f) | 0x80);
    std::ostringstream out;
    for (std::size_t index = 0; index < bytes.size(); ++index) {
        if (index == 4 || index == 6 || index == 8 || index == 10) out << "-";
        out << std::hex << std::setw(2) << std::setfill('0') << static_cast<int>(bytes[index]);
    }
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
    auto snapshot = parseSnapshotJson(std::string(raw.begin(), raw.end()));
    snapshot.syncStatus = "Loaded";
    return snapshot;
}

std::string serializeSnapshotJson(const VaultSnapshot& snapshot) {
    std::ostringstream out;
    out << "{\"entries\":[";
    for (std::size_t index = 0; index < snapshot.entries.size(); ++index) {
        if (index > 0) out << ",";
        out << entryJson(snapshot.entries[index]);
    }
    out << "],\"categories\":[";
    for (std::size_t index = 0; index < snapshot.categories.size(); ++index) {
        if (index > 0) out << ",";
        out << "\"" << escapeJson(snapshot.categories[index]) << "\"";
    }
    out << "],\"categoryTemplates\":[";
    for (std::size_t templateIndex = 0; templateIndex < snapshot.categoryTemplates.size(); ++templateIndex) {
        const auto& templateEntry = snapshot.categoryTemplates[templateIndex];
        if (templateIndex > 0) out << ",";
        out << "{\"category\":\"" << escapeJson(templateEntry.category) << "\",\"fields\":[";
        for (std::size_t fieldIndex = 0; fieldIndex < templateEntry.fields.size(); ++fieldIndex) {
            const auto& field = templateEntry.fields[fieldIndex];
            if (fieldIndex > 0) out << ",";
            out << "{\"id\":\"" << escapeJson(field.id) << "\",\"name\":\"" << escapeJson(field.name) << "\"}";
        }
        out << "]}";
    }
    out << "],\"tags\":" << jsonStringArray(snapshot.tags)
        << ",\"security\":{\"requireTotp\":" << (snapshot.requireTotp ? "true" : "false")
        << ",\"totpSecret\":" << jsonString(snapshot.totpSecret) << "}"
        << ",\"syncStatus\":" << jsonString(snapshot.syncStatus)
        << ",\"backupStatus\":" << jsonString(snapshot.backupStatus)
        << ",\"lastBackupStatus\":" << jsonString(snapshot.backupStatus)
        << ",\"updatedAt\":" << jsonString(snapshot.updatedAt.empty() ? isoTimestamp() : snapshot.updatedAt) << "}";
    return out.str();
}

VaultSnapshot parseSnapshotJson(const std::string& json) {
    JsonReader reader(json);
    VaultSnapshot snapshot;
    reader.objectStart();
    if (!reader.objectEnd()) {
        do {
            const auto key = reader.key();
            if (key == "entries") {
                snapshot.entries = readVaultEntryArray(reader);
            } else if (key == "categories") {
                snapshot.categories = readStringArray(reader);
            } else if (key == "categoryTemplates") {
                snapshot.categoryTemplates = readCategoryTemplateArray(reader);
            } else if (key == "tags") {
                snapshot.tags = readStringArray(reader);
            } else if (key == "security") {
                readSecuritySettings(reader, snapshot);
            } else if (key == "syncStatus") {
                snapshot.syncStatus = reader.string();
            } else if (key == "backupStatus" || key == "lastBackupStatus") {
                snapshot.backupStatus = reader.string();
            } else if (key == "updatedAt") {
                snapshot.updatedAt = reader.string();
            } else if (key == "requireTotp") {
                snapshot.requireTotp = reader.boolean();
            } else if (key == "totpSecret") {
                snapshot.totpSecret = reader.string();
            } else {
                reader.skipValue();
            }
        } while (reader.commaIfPresent());
        if (!reader.objectEnd()) throw std::runtime_error("Expected JSON object end.");
    }
    if (snapshot.updatedAt.empty()) snapshot.updatedAt = isoTimestamp();
    if (snapshot.categories.empty()) snapshot.categories = rebuildCategories(snapshot.entries);
    if (snapshot.tags.empty()) snapshot.tags = rebuildTags(snapshot.entries);
    if (snapshot.categoryTemplates.empty()) {
        for (const auto& category : snapshot.categories) {
            snapshot.categoryTemplates.push_back(CategoryTemplate{category, defaultCategoryFields()});
        }
    }
    return snapshot;
}

std::string serializeEnvelopeText(const VaultEnvelope& envelope) {
    std::ostringstream out;
    out << "schemaVersion=" << envelope.schemaVersion << "\n"
        << "updatedAt=" << envelope.updatedAt << "\n"
        << "salt=" << envelope.masterKeyRecord.saltBase64 << "\n"
        << "iterations=" << envelope.masterKeyRecord.iterations << "\n"
        << "verifier=" << envelope.masterKeyRecord.verifierBase64 << "\n"
        << "metadataSalt=" << envelope.masterKeyRecord.metadataSaltBase64 << "\n"
        << "metadataIterations=" << envelope.masterKeyRecord.metadataIterations << "\n"
        << "payloadVersion=" << envelope.encryptedVault.version << "\n"
        << "nonce=" << envelope.encryptedVault.nonceBase64 << "\n"
        << "ciphertext=" << envelope.encryptedVault.ciphertextBase64 << "\n"
        << "mac=" << envelope.encryptedVault.macBase64 << "\n";
    return out.str();
}

VaultEnvelope parseEnvelopeText(const std::string& text) {
    VaultEnvelope envelope;
    std::istringstream in(text);
    std::string line;
    while (std::getline(in, line)) {
        const auto split = line.find('=');
        if (split == std::string::npos) continue;
        const auto key = line.substr(0, split);
        const auto value = line.substr(split + 1);
        if (key == "schemaVersion") envelope.schemaVersion = std::stoi(value);
        else if (key == "updatedAt") envelope.updatedAt = value;
        else if (key == "salt") envelope.masterKeyRecord.saltBase64 = value;
        else if (key == "iterations") envelope.masterKeyRecord.iterations = std::stoi(value);
        else if (key == "verifier") envelope.masterKeyRecord.verifierBase64 = value;
        else if (key == "metadataSalt") envelope.masterKeyRecord.metadataSaltBase64 = value;
        else if (key == "metadataIterations") envelope.masterKeyRecord.metadataIterations = std::stoi(value);
        else if (key == "payloadVersion") envelope.encryptedVault.version = std::stoi(value);
        else if (key == "nonce") envelope.encryptedVault.nonceBase64 = value;
        else if (key == "ciphertext") envelope.encryptedVault.ciphertextBase64 = value;
        else if (key == "mac") envelope.encryptedVault.macBase64 = value;
    }
    if (envelope.masterKeyRecord.saltBase64.empty() ||
        envelope.masterKeyRecord.verifierBase64.empty() ||
        envelope.encryptedVault.nonceBase64.empty() ||
        envelope.encryptedVault.ciphertextBase64.empty() ||
        envelope.encryptedVault.macBase64.empty()) {
        throw std::runtime_error("Vault envelope file is incomplete.");
    }
    if (envelope.updatedAt.empty()) envelope.updatedAt = isoTimestamp();
    if (envelope.masterKeyRecord.metadataSaltBase64.empty()) {
        envelope.masterKeyRecord.metadataSaltBase64 = envelope.masterKeyRecord.saltBase64;
    }
    if (envelope.masterKeyRecord.metadataIterations <= 0) {
        envelope.masterKeyRecord.metadataIterations = envelope.masterKeyRecord.iterations;
    }
    return envelope;
}

void saveEnvelopeFile(const std::string& path, const VaultEnvelope& envelope) {
    std::ofstream out(path, std::ios::binary | std::ios::trunc);
    if (!out) throw std::runtime_error("Unable to open vault file for writing.");
    out << serializeEnvelopeText(envelope);
    if (!out) throw std::runtime_error("Unable to write vault file.");
}

VaultEnvelope loadEnvelopeFile(const std::string& path) {
    std::ifstream in(path, std::ios::binary);
    if (!in) throw std::runtime_error("Unable to open vault file.");
    std::ostringstream buffer;
    buffer << in.rdbuf();
    return parseEnvelopeText(buffer.str());
}

VaultEntry makeEntry(const std::string& label, const std::string& type, const std::string& username, const std::string& secret) {
    VaultEntry entry;
    entry.id = randomId();
    entry.label = label;
    entry.type = type.empty() ? "credential" : type;
    entry.username = username;
    entry.secret = secret;
    entry.createdAt = isoTimestamp();
    entry.updatedAt = entry.createdAt;
    entry.updatedBy = "native-cli";
    entry.version = {{"native-cli", 1}};
    return entry;
}

std::vector<FieldTemplate> defaultCategoryFields() {
    return fieldsFromNames({"名称", "备注"});
}

std::vector<FieldTemplate> categoryFieldsForPreset(CategoryTypePreset preset, const std::vector<std::string>& customFieldNames) {
    std::vector<FieldTemplate> fields = defaultCategoryFields();
    std::vector<std::string> presetNames;
    switch (preset) {
        case CategoryTypePreset::Server:
            presetNames = {"IP地址", "端口", "关联账号"};
            break;
        case CategoryTypePreset::Service:
            presetNames = {"服务入口", "关联账号", "关联服务器"};
            break;
        case CategoryTypePreset::Account:
            presetNames = {"入口"};
            break;
    }
    auto presetFields = fieldsFromNames(presetNames);
    fields.insert(fields.end(), presetFields.begin(), presetFields.end());
    auto customFields = fieldsFromNames(customFieldNames);
    fields.insert(fields.end(), customFields.begin(), customFields.end());
    return normalizeFieldTemplates(fields);
}

std::vector<FieldTemplate> categoryFieldsWithCustom(const std::vector<std::string>& customFieldNames) {
    std::vector<FieldTemplate> fields = defaultCategoryFields();
    auto customFields = fieldsFromNames(customFieldNames);
    fields.insert(fields.end(), customFields.begin(), customFields.end());
    return normalizeFieldTemplates(fields);
}

bool addCategory(VaultSnapshot& snapshot, const std::string& category, const std::vector<FieldTemplate>& fields) {
    const auto clean = trimCopy(category);
    if (clean.empty()) return false;
    const auto key = lowerCopy(clean);
    for (const auto& existing : snapshot.categories) {
        if (lowerCopy(trimCopy(existing)) == key) return false;
    }
    snapshot.categories.push_back(clean);
    std::sort(snapshot.categories.begin(), snapshot.categories.end());
    upsertCategoryTemplate(snapshot, clean, fields);
    return true;
}

bool addCategory(VaultSnapshot& snapshot, const std::string& category, CategoryTypePreset preset, const std::vector<std::string>& customFieldNames) {
    return addCategory(snapshot, category, categoryFieldsForPreset(preset, customFieldNames));
}

std::vector<VaultEntry> filterEntries(const std::vector<VaultEntry>& entries, const std::string& query, const std::string& type) {
    const auto terms = parseSearchTerms(query);
    std::vector<VaultEntry> result;
    for (const auto& entry : entries) {
        if (entry.isDeleted) continue;
        if (type != "all" && entry.type != type) continue;
        bool matches = true;
        for (const auto& term : terms) {
            if (!matchesSearchTerm(entry, term)) {
                matches = false;
                break;
            }
        }
        if (terms.empty() || matches) result.push_back(entry);
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

std::string serializeSyncPayloadJson(const VaultSyncPayload& payload) {
    return syncPayloadJson(payload);
}

VaultSyncPayload parseSyncPayloadJson(const std::string& json) {
    JsonReader reader(json);
    VaultSyncPayload payload;
    bool hasSnapshot = false;
    reader.objectStart();
    if (!reader.objectEnd()) {
        do {
            const auto key = reader.key();
            if (key == "version") {
                payload.version = reader.integer();
            } else if (key == "exportedAt") {
                payload.exportedAt = reader.string();
            } else if (key == "deviceId") {
                payload.deviceId = reader.string();
            } else if (key == "revision") {
                payload.revision = reader.integer();
            } else if (key == "snapshot") {
                payload.snapshot = parseSnapshotJson(reader.rawValue());
                hasSnapshot = true;
            } else {
                reader.skipValue();
            }
        } while (reader.commaIfPresent());
        if (!reader.objectEnd()) throw std::runtime_error("Expected JSON object end.");
    }
    if (!hasSnapshot) throw std::runtime_error("Remote sync payload is invalid.");
    if (payload.exportedAt.empty()) payload.exportedAt = payload.snapshot.updatedAt;
    return payload;
}

SnapshotSyncResult synchronizeSnapshots(
    const VaultSnapshot& localSnapshot,
    const SyncSettingsState& settings,
    const std::string& remotePayloadJson,
    const std::string& remoteFingerprint
) {
    const auto now = isoTimestamp();
    auto resultSettings = settings;
    auto finish = [&](SnapshotSyncResult result, int revision) {
        resultSettings.lastSyncRevision = revision;
        resultSettings.lastSyncAt = now;
        resultSettings.lastSyncStatus = "success";
        resultSettings.lastSyncMessage = syncResultMessage(result.stats, revision);
        resultSettings.lastRemoteFingerprint = result.uploaded ? "" : remoteFingerprint;
        resultSettings.hasLocalChanges = false;
        result.settings = resultSettings;
        return result;
    };

    auto local = localSnapshot;
    if (local.updatedAt.empty()) local.updatedAt = now;
    const VaultSyncPayload localPayload{1, now, resultSettings.deviceId, resultSettings.lastSyncRevision, local};
    const auto remoteRaw = trimCopy(remotePayloadJson);
    if (remoteRaw.empty()) {
        SnapshotSyncResult result;
        result.snapshot = local;
        result.stats = SyncMergeStats{
            static_cast<int>(local.entries.size()),
            0,
            static_cast<int>(std::count_if(local.entries.begin(), local.entries.end(), [](const auto& entry) { return entry.isDeleted; }))
        };
        result.uploaded = true;
        result.uploadPayloadJson = serializeSyncPayloadJson(localPayload);
        return finish(result, localPayload.revision);
    }

    const auto remotePayload = parseSyncPayloadJson(remoteRaw);
    if (resultSettings.hasLocalChanges && remotePayload.revision <= resultSettings.lastSyncRevision) {
        const auto nextRevision = resultSettings.lastSyncRevision + 1;
        auto uploadPayload = localPayload;
        uploadPayload.revision = nextRevision;
        SnapshotSyncResult result;
        result.snapshot = local;
        result.stats = SyncMergeStats{
            static_cast<int>(local.entries.size()),
            0,
            static_cast<int>(std::count_if(local.entries.begin(), local.entries.end(), [](const auto& entry) { return entry.isDeleted; }))
        };
        result.uploaded = true;
        result.uploadPayloadJson = serializeSyncPayloadJson(uploadPayload);
        return finish(result, nextRevision);
    }

    const auto mergeResult = mergeEntries(local.entries, remotePayload.snapshot.entries, resultSettings.conflictStrategy);
    const auto mergedSnapshot = mergeSnapshotsForSync(local, remotePayload.snapshot, mergeResult.entries, resultSettings.hasLocalChanges);
    if (snapshotsEquivalent(mergedSnapshot, remotePayload.snapshot)) {
        SnapshotSyncResult result;
        result.snapshot = mergedSnapshot;
        result.stats = mergeResult.stats;
        result.uploaded = false;
        result.appliedRemote = !snapshotsEquivalent(mergedSnapshot, local);
        return finish(result, remotePayload.revision);
    }

    const auto mergedRevision = std::max(localPayload.revision, remotePayload.revision) + 1;
    SnapshotSyncResult result;
    result.snapshot = mergedSnapshot;
    result.stats = mergeResult.stats;
    result.uploaded = true;
    result.appliedRemote = !snapshotsEquivalent(mergedSnapshot, local);
    result.uploadPayloadJson = serializeSyncPayloadJson(VaultSyncPayload{1, now, resultSettings.deviceId, mergedRevision, mergedSnapshot});
    return finish(result, mergedRevision);
}

ObjectSyncRequest buildObjectSyncRequest(const ObjectSyncConfig& config) {
    const auto objectKey = defaultObjectKey(config.objectKey);
    if (config.provider == ObjectSyncProvider::None) {
        ObjectSyncRequest request;
        request.provider = config.provider;
        request.objectKey = objectKey;
        return request;
    }

    requireObjectStoreCredentials(config);
    const auto baseUrl = buildObjectSyncBaseUrl(config);
    ObjectSyncRequest request;
    request.provider = config.provider;
    request.objectKey = objectKey;
    request.baseUrl = baseUrl;
    request.objectUrl = joinUrlPath(baseUrl, objectKey);
    request.requiresCredentials = requiresObjectStoreCredentials(config.provider);
    return request;
}

ObjectSyncRequest buildObjectSyncSignedRequest(
    const ObjectSyncConfig& config,
    const std::string& method,
    const std::string& body,
    std::time_t now
) {
    auto request = buildObjectSyncRequest(config);
    request.method = upperCopy(trimCopy(method).empty() ? "GET" : trimCopy(method));
    request.body = body;
    const std::string contentType = request.method == "PUT" ? "application/json" : "";
    switch (config.provider) {
        case ObjectSyncProvider::TencentCos:
            applyTencentCosHeaders(request, config, now, contentType);
            break;
        case ObjectSyncProvider::AliyunOss:
            applyAliyunOssHeaders(request, config, now, contentType);
            break;
        case ObjectSyncProvider::WebDav:
        case ObjectSyncProvider::S3Presigned:
        case ObjectSyncProvider::None:
            if (!contentType.empty()) request.headers["Content-Type"] = contentType;
            break;
    }
    return request;
}

} // namespace pm
