#include "vault_cli.hpp"

#include "vault_core.hpp"

#include <curl/curl.h>

#include <iostream>
#include <algorithm>
#include <cctype>
#include <ctime>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <map>
#include <stdexcept>
#include <sstream>
#include <string>
#include <vector>

namespace pm {
namespace {
namespace fs = std::filesystem;

constexpr int kBackupRetentionCount = 5;

struct CliOptions {
    std::string vaultPath;
};

void printUsage(const char* platformName, const char* defaultVaultPath) {
    std::cout << "Password Manager " << platformName << " Native\n"
              << "Commands:\n"
              << "  init <password> [--vault <path>]\n"
              << "                              Create an encrypted vault file\n"
              << "  status <password> [--vault <path>]\n"
              << "                              Unlock and print vault counts\n"
              << "  add-category <password> <name> [--shortcut server|service|account] [--field <name>]... [--vault <path>]\n"
              << "                              Persist a category template; shortcuts add editable custom fields\n"
              << "  add-entry <password> --label <text> [--type credential|server|service]\n"
              << "            [--username <value>] [--secret <value>] [--category <name>]\n"
              << "            [--tag <name>]... [--note <text>] [--field <name=value>]... [--vault <path>]\n"
              << "                              Add an encrypted vault entry\n"
              << "  list <password> [--query <text>] [--type all|credential|server|service]\n"
              << "       [--show-secret] [--vault <path>]\n"
              << "                              Search entries without exposing secrets by default\n"
              << "  show-entry <password> <id> [--show-secret] [--vault <path>]\n"
              << "                              Print one entry as JSON\n"
              << "  delete-entry <password> <id> [--vault <path>]\n"
              << "                              Soft-delete one entry in the encrypted vault\n"
              << "  backup <password> [--vault <path>] [--backup-dir <dir>]\n"
              << "                              Copy the encrypted vault envelope to backups/, keeping newest 5\n"
              << "  list-backups [--vault <path>] [--backup-dir <dir>]\n"
              << "                              List local encrypted backup envelopes\n"
              << "  restore-backup <password> [latest|file] [--vault <path>] [--backup-dir <dir>]\n"
              << "                              Validate and restore an encrypted backup envelope\n"
              << "  export-snapshot <password> [--vault <path>] [--out <path>] [--export-dir <dir>]\n"
              << "                              Write a plaintext JSON snapshot export\n"
              << "  import-snapshot <password> --in <path> [--vault <path>]\n"
              << "                              Replace the unlocked vault with a plaintext JSON snapshot\n"
              << "  sync <password> --provider webdav|s3-presigned|tencent-cos|aliyun-oss [options]\n"
              << "                              Merge local vault with remote object storage and upload when needed\n"
              << "  category <name> [--shortcut server|service|account] [--field <name>]...\n"
              << "                              Print category template JSON without saving\n"
              << "  totp <base32-secret> <unix> Generate a TOTP code\n"
              << "  self-test                   Run a small runtime check\n"
              << "\nDefault vault: " << defaultVaultPath << "\n";
}

CategoryTypePreset parseShortcut(const std::string& value) {
    if (value == "server") return CategoryTypePreset::Server;
    if (value == "service") return CategoryTypePreset::Service;
    if (value == "account") return CategoryTypePreset::Account;
    throw std::invalid_argument("shortcut must be server, service, or account");
}

std::string parseEntryType(const std::string& value) {
    if (value == "credential" || value == "server" || value == "service") return value;
    throw std::invalid_argument("entry type must be credential, server, or service");
}

std::vector<FieldTemplate> fieldsForCli(bool hasPreset, CategoryTypePreset preset, const std::vector<std::string>& customFields) {
    return hasPreset ? categoryFieldsForPreset(preset, customFields) : categoryFieldsWithCustom(customFields);
}

CliOptions parseVaultOption(int argc, char** argv, int start, const char* defaultVaultPath) {
    CliOptions options{defaultVaultPath};
    for (int i = start; i < argc; ++i) {
        const std::string arg = argv[i];
        if (arg == "--vault") {
            if (++i >= argc) throw std::invalid_argument("--vault requires a value");
            options.vaultPath = argv[i];
        } else if (arg.rfind("--vault=", 0) == 0) {
            options.vaultPath = arg.substr(8);
        } else {
            throw std::invalid_argument("unknown option: " + arg);
        }
    }
    return options;
}

struct CategoryArgs {
    std::string name;
    std::vector<std::string> customFields;
    CategoryTypePreset preset = CategoryTypePreset::Account;
    bool hasPreset = false;
    std::string vaultPath;
};

struct EntryArgs {
    std::string label;
    std::string type = "credential";
    std::string username;
    std::string secret;
    std::string category;
    std::string notes;
    std::vector<std::string> tags;
    std::vector<CustomField> customFields;
    std::string vaultPath;
};

struct ListArgs {
    std::string query;
    std::string type = "all";
    bool showSecret = false;
    std::string vaultPath;
};

struct ShowEntryArgs {
    bool showSecret = false;
    std::string vaultPath;
};

struct BackupArgs {
    std::string vaultPath;
    std::string backupDir;
    std::string backupName = "latest";
    bool hasBackupName = false;
};

struct ExportSnapshotArgs {
    std::string vaultPath;
    std::string exportDir;
    std::string outPath;
};

struct ImportSnapshotArgs {
    std::string vaultPath;
    std::string inPath;
};

struct SyncArgs {
    std::string vaultPath;
    std::string statePath;
    std::string provider;
    ObjectSyncConfig config;
    std::string downloadUrl;
    std::string uploadUrl;
    std::string webDavUsername;
    std::string webDavPassword;
    std::string deviceId;
    std::string conflictStrategy;
};

struct HttpResult {
    long statusCode = 0;
    std::string body;
    std::string fingerprint;
};

struct HeaderAccumulator {
    std::string eTag;
    std::string lastModified;
    std::string contentLength;
};

struct CurlGlobal {
    CurlGlobal() {
        if (curl_global_init(CURL_GLOBAL_DEFAULT) != CURLE_OK) {
            throw std::runtime_error("Unable to initialize libcurl.");
        }
    }
    ~CurlGlobal() {
        curl_global_cleanup();
    }
};

std::string maskedSecret(const std::string& value, bool showSecret) {
    if (showSecret) return value;
    return value.empty() ? "" : "******";
}

std::string trimAscii(std::string value) {
    const auto first = value.find_first_not_of(" \t\n\r\f\v");
    if (first == std::string::npos) return "";
    const auto last = value.find_last_not_of(" \t\n\r\f\v");
    return value.substr(first, last - first + 1);
}

std::string lowerAscii(std::string value) {
    std::transform(value.begin(), value.end(), value.begin(), [](unsigned char ch) {
        return static_cast<char>(std::tolower(ch));
    });
    return value;
}

std::string defaultSyncStatePath(const std::string& vaultPath) {
    return vaultPath + ".sync-state";
}

fs::path syncStatePointerPath(const std::string& vaultPath) {
    return fs::path(vaultPath + ".sync-state-path");
}

std::string readOptionalLine(const fs::path& path) {
    std::ifstream in(path, std::ios::binary);
    if (!in) return "";
    std::string line;
    std::getline(in, line);
    return trimAscii(line);
}

std::string resolveSyncStatePath(const std::string& vaultPath, const std::string& explicitStatePath) {
    if (!explicitStatePath.empty()) return explicitStatePath;
    const auto linkedPath = readOptionalLine(syncStatePointerPath(vaultPath));
    return linkedPath.empty() ? defaultSyncStatePath(vaultPath) : linkedPath;
}

bool isHttpSuccess(long statusCode) {
    return statusCode >= 200 && statusCode < 300;
}

bool isHttpDownloadSuccess(long statusCode) {
    return isHttpSuccess(statusCode) || statusCode == 404;
}

std::string syncFingerprint(const HeaderAccumulator& headers) {
    std::vector<std::string> parts;
    if (!headers.eTag.empty()) parts.push_back("etag:" + headers.eTag);
    if (!headers.lastModified.empty()) parts.push_back("modified:" + headers.lastModified);
    if (parts.empty()) return "";
    if (!headers.contentLength.empty()) parts.push_back("length:" + headers.contentLength);
    std::ostringstream out;
    for (std::size_t index = 0; index < parts.size(); ++index) {
        if (index > 0) out << "|";
        out << parts[index];
    }
    return out.str();
}

std::size_t curlWriteCallback(char* ptr, std::size_t size, std::size_t nmemb, void* userdata) {
    auto* body = static_cast<std::string*>(userdata);
    body->append(ptr, size * nmemb);
    return size * nmemb;
}

std::size_t curlHeaderCallback(char* buffer, std::size_t size, std::size_t nitems, void* userdata) {
    const auto total = size * nitems;
    std::string line(buffer, total);
    const auto split = line.find(':');
    if (split == std::string::npos) return total;
    const auto key = lowerAscii(trimAscii(line.substr(0, split)));
    const auto value = trimAscii(line.substr(split + 1));
    auto* headers = static_cast<HeaderAccumulator*>(userdata);
    if (key == "etag") {
        headers->eTag = value;
    } else if (key == "last-modified") {
        headers->lastModified = value;
    } else if (key == "content-length") {
        headers->contentLength = value;
    }
    return total;
}

CustomField parseCustomField(const std::string& value) {
    const auto split = value.find('=');
    const auto fallbackSplit = value.find(':');
    const auto pos = split == std::string::npos ? fallbackSplit : split;
    if (pos == std::string::npos || pos == 0) throw std::invalid_argument("--field requires name=value");
    CustomField field;
    field.id = randomId();
    field.name = value.substr(0, pos);
    field.value = value.substr(pos + 1);
    return field;
}

EntryArgs parseEntryArgs(int argc, char** argv, int start, const char* defaultVaultPath) {
    EntryArgs args;
    args.vaultPath = defaultVaultPath;
    for (int i = start; i < argc; ++i) {
        const std::string arg = argv[i];
        auto requireValue = [&](const std::string& option) -> std::string {
            if (++i >= argc) throw std::invalid_argument(option + " requires a value");
            return argv[i];
        };
        if (arg == "--label") {
            args.label = requireValue(arg);
        } else if (arg.rfind("--label=", 0) == 0) {
            args.label = arg.substr(8);
        } else if (arg == "--type") {
            args.type = parseEntryType(requireValue(arg));
        } else if (arg.rfind("--type=", 0) == 0) {
            args.type = parseEntryType(arg.substr(7));
        } else if (arg == "--username") {
            args.username = requireValue(arg);
        } else if (arg.rfind("--username=", 0) == 0) {
            args.username = arg.substr(11);
        } else if (arg == "--secret") {
            args.secret = requireValue(arg);
        } else if (arg.rfind("--secret=", 0) == 0) {
            args.secret = arg.substr(9);
        } else if (arg == "--category") {
            args.category = requireValue(arg);
        } else if (arg.rfind("--category=", 0) == 0) {
            args.category = arg.substr(11);
        } else if (arg == "--tag") {
            args.tags.push_back(requireValue(arg));
        } else if (arg.rfind("--tag=", 0) == 0) {
            args.tags.push_back(arg.substr(6));
        } else if (arg == "--note" || arg == "--notes") {
            args.notes = requireValue(arg);
        } else if (arg.rfind("--note=", 0) == 0) {
            args.notes = arg.substr(7);
        } else if (arg.rfind("--notes=", 0) == 0) {
            args.notes = arg.substr(8);
        } else if (arg == "--field") {
            args.customFields.push_back(parseCustomField(requireValue(arg)));
        } else if (arg.rfind("--field=", 0) == 0) {
            args.customFields.push_back(parseCustomField(arg.substr(8)));
        } else if (arg == "--vault") {
            args.vaultPath = requireValue(arg);
        } else if (arg.rfind("--vault=", 0) == 0) {
            args.vaultPath = arg.substr(8);
        } else {
            throw std::invalid_argument("unknown entry option: " + arg);
        }
    }
    if (args.label.empty()) throw std::invalid_argument("--label is required");
    return args;
}

ListArgs parseListArgs(int argc, char** argv, int start, const char* defaultVaultPath) {
    ListArgs args;
    args.vaultPath = defaultVaultPath;
    for (int i = start; i < argc; ++i) {
        const std::string arg = argv[i];
        auto requireValue = [&](const std::string& option) -> std::string {
            if (++i >= argc) throw std::invalid_argument(option + " requires a value");
            return argv[i];
        };
        if (arg == "--query") {
            args.query = requireValue(arg);
        } else if (arg.rfind("--query=", 0) == 0) {
            args.query = arg.substr(8);
        } else if (arg == "--type") {
            args.type = requireValue(arg);
        } else if (arg.rfind("--type=", 0) == 0) {
            args.type = arg.substr(7);
        } else if (arg == "--show-secret") {
            args.showSecret = true;
        } else if (arg == "--vault") {
            args.vaultPath = requireValue(arg);
        } else if (arg.rfind("--vault=", 0) == 0) {
            args.vaultPath = arg.substr(8);
        } else {
            throw std::invalid_argument("unknown list option: " + arg);
        }
    }
    if (args.type != "all") args.type = parseEntryType(args.type);
    return args;
}

ShowEntryArgs parseShowEntryArgs(int argc, char** argv, int start, const char* defaultVaultPath) {
    ShowEntryArgs args;
    args.vaultPath = defaultVaultPath;
    for (int i = start; i < argc; ++i) {
        const std::string arg = argv[i];
        if (arg == "--show-secret") {
            args.showSecret = true;
        } else if (arg == "--vault") {
            if (++i >= argc) throw std::invalid_argument("--vault requires a value");
            args.vaultPath = argv[i];
        } else if (arg.rfind("--vault=", 0) == 0) {
            args.vaultPath = arg.substr(8);
        } else {
            throw std::invalid_argument("unknown show-entry option: " + arg);
        }
    }
    return args;
}

CategoryArgs parseCategoryArgs(
    int argc,
    char** argv,
    int nameIndex,
    int optionStart,
    const char* defaultVaultPath,
    bool allowVault
) {
    if (argc <= nameIndex) throw std::invalid_argument("category name is required");
    CategoryArgs args;
    args.name = argv[nameIndex];
    args.vaultPath = defaultVaultPath;
    for (int i = optionStart; i < argc; ++i) {
        const std::string arg = argv[i];
        if (arg == "--shortcut" || arg == "--preset") {
            if (++i >= argc) throw std::invalid_argument(arg + " requires a value");
            args.preset = parseShortcut(argv[i]);
            args.hasPreset = true;
        } else if (arg.rfind("--shortcut=", 0) == 0) {
            args.preset = parseShortcut(arg.substr(11));
            args.hasPreset = true;
        } else if (arg.rfind("--preset=", 0) == 0) {
            args.preset = parseShortcut(arg.substr(9));
            args.hasPreset = true;
        } else if (arg == "--field") {
            if (++i >= argc) throw std::invalid_argument("--field requires a value");
            args.customFields.push_back(argv[i]);
        } else if (arg.rfind("--field=", 0) == 0) {
            args.customFields.push_back(arg.substr(8));
        } else if (allowVault && arg == "--vault") {
            if (++i >= argc) throw std::invalid_argument("--vault requires a value");
            args.vaultPath = argv[i];
        } else if (allowVault && arg.rfind("--vault=", 0) == 0) {
            args.vaultPath = arg.substr(8);
        } else {
            throw std::invalid_argument("unknown category option: " + arg);
        }
    }
    return args;
}

BackupArgs parseBackupArgs(int argc, char** argv, int start, const char* defaultVaultPath, bool allowBackupName) {
    BackupArgs args;
    args.vaultPath = defaultVaultPath;
    for (int i = start; i < argc; ++i) {
        const std::string arg = argv[i];
        auto requireValue = [&](const std::string& option) -> std::string {
            if (++i >= argc) throw std::invalid_argument(option + " requires a value");
            return argv[i];
        };
        if (arg == "--vault") {
            args.vaultPath = requireValue(arg);
        } else if (arg.rfind("--vault=", 0) == 0) {
            args.vaultPath = arg.substr(8);
        } else if (arg == "--backup-dir") {
            args.backupDir = requireValue(arg);
        } else if (arg.rfind("--backup-dir=", 0) == 0) {
            args.backupDir = arg.substr(13);
        } else if (allowBackupName && arg == "--name") {
            args.backupName = requireValue(arg);
            args.hasBackupName = true;
        } else if (allowBackupName && arg.rfind("--name=", 0) == 0) {
            args.backupName = arg.substr(7);
            args.hasBackupName = true;
        } else if (allowBackupName && !args.hasBackupName && !arg.empty() && arg[0] != '-') {
            args.backupName = arg;
            args.hasBackupName = true;
        } else {
            throw std::invalid_argument("unknown backup option: " + arg);
        }
    }
    return args;
}

ExportSnapshotArgs parseExportSnapshotArgs(int argc, char** argv, int start, const char* defaultVaultPath) {
    ExportSnapshotArgs args;
    args.vaultPath = defaultVaultPath;
    for (int i = start; i < argc; ++i) {
        const std::string arg = argv[i];
        auto requireValue = [&](const std::string& option) -> std::string {
            if (++i >= argc) throw std::invalid_argument(option + " requires a value");
            return argv[i];
        };
        if (arg == "--vault") {
            args.vaultPath = requireValue(arg);
        } else if (arg.rfind("--vault=", 0) == 0) {
            args.vaultPath = arg.substr(8);
        } else if (arg == "--out") {
            args.outPath = requireValue(arg);
        } else if (arg.rfind("--out=", 0) == 0) {
            args.outPath = arg.substr(6);
        } else if (arg == "--export-dir") {
            args.exportDir = requireValue(arg);
        } else if (arg.rfind("--export-dir=", 0) == 0) {
            args.exportDir = arg.substr(13);
        } else {
            throw std::invalid_argument("unknown export option: " + arg);
        }
    }
    return args;
}

ImportSnapshotArgs parseImportSnapshotArgs(int argc, char** argv, int start, const char* defaultVaultPath) {
    ImportSnapshotArgs args;
    args.vaultPath = defaultVaultPath;
    for (int i = start; i < argc; ++i) {
        const std::string arg = argv[i];
        auto requireValue = [&](const std::string& option) -> std::string {
            if (++i >= argc) throw std::invalid_argument(option + " requires a value");
            return argv[i];
        };
        if (arg == "--vault") {
            args.vaultPath = requireValue(arg);
        } else if (arg.rfind("--vault=", 0) == 0) {
            args.vaultPath = arg.substr(8);
        } else if (arg == "--in" || arg == "--input") {
            args.inPath = requireValue(arg);
        } else if (arg.rfind("--in=", 0) == 0) {
            args.inPath = arg.substr(5);
        } else if (arg.rfind("--input=", 0) == 0) {
            args.inPath = arg.substr(8);
        } else {
            throw std::invalid_argument("unknown import option: " + arg);
        }
    }
    if (args.inPath.empty()) throw std::invalid_argument("--in is required");
    return args;
}

ObjectSyncProvider parseProvider(const std::string& value) {
    const auto normalized = lowerAscii(trimAscii(value));
    if (normalized == "webdav") return ObjectSyncProvider::WebDav;
    if (normalized == "s3-presigned" || normalized == "presigned") return ObjectSyncProvider::S3Presigned;
    if (normalized == "tencent-cos" || normalized == "cos") return ObjectSyncProvider::TencentCos;
    if (normalized == "aliyun-oss" || normalized == "oss") return ObjectSyncProvider::AliyunOss;
    throw std::invalid_argument("provider must be webdav, s3-presigned, tencent-cos, or aliyun-oss");
}

SyncArgs parseSyncArgs(int argc, char** argv, int start, const char* defaultVaultPath) {
    SyncArgs args;
    args.vaultPath = defaultVaultPath;
    args.config.objectKey = "vault.sync.json";
    for (int i = start; i < argc; ++i) {
        const std::string arg = argv[i];
        auto requireValue = [&](const std::string& option) -> std::string {
            if (++i >= argc) throw std::invalid_argument(option + " requires a value");
            return argv[i];
        };
        if (arg == "--vault") {
            args.vaultPath = requireValue(arg);
        } else if (arg.rfind("--vault=", 0) == 0) {
            args.vaultPath = arg.substr(8);
        } else if (arg == "--state") {
            args.statePath = requireValue(arg);
        } else if (arg.rfind("--state=", 0) == 0) {
            args.statePath = arg.substr(8);
        } else if (arg == "--provider") {
            args.provider = requireValue(arg);
            args.config.provider = parseProvider(args.provider);
        } else if (arg.rfind("--provider=", 0) == 0) {
            args.provider = arg.substr(11);
            args.config.provider = parseProvider(args.provider);
        } else if (arg == "--endpoint") {
            args.config.endpoint = requireValue(arg);
        } else if (arg.rfind("--endpoint=", 0) == 0) {
            args.config.endpoint = arg.substr(11);
        } else if (arg == "--custom-url") {
            args.config.customUrl = requireValue(arg);
        } else if (arg.rfind("--custom-url=", 0) == 0) {
            args.config.customUrl = arg.substr(13);
        } else if (arg == "--bucket") {
            args.config.bucket = requireValue(arg);
        } else if (arg.rfind("--bucket=", 0) == 0) {
            args.config.bucket = arg.substr(9);
        } else if (arg == "--appid" || arg == "--app-id") {
            args.config.appId = requireValue(arg);
        } else if (arg.rfind("--appid=", 0) == 0) {
            args.config.appId = arg.substr(8);
        } else if (arg.rfind("--app-id=", 0) == 0) {
            args.config.appId = arg.substr(9);
        } else if (arg == "--ak" || arg == "--access-key" || arg == "--access-key-id") {
            args.config.accessKeyId = requireValue(arg);
        } else if (arg.rfind("--ak=", 0) == 0) {
            args.config.accessKeyId = arg.substr(5);
        } else if (arg.rfind("--access-key=", 0) == 0) {
            args.config.accessKeyId = arg.substr(13);
        } else if (arg.rfind("--access-key-id=", 0) == 0) {
            args.config.accessKeyId = arg.substr(16);
        } else if (arg == "--sk" || arg == "--secret-key" || arg == "--secret-access-key") {
            args.config.secretAccessKey = requireValue(arg);
        } else if (arg.rfind("--sk=", 0) == 0) {
            args.config.secretAccessKey = arg.substr(5);
        } else if (arg.rfind("--secret-key=", 0) == 0) {
            args.config.secretAccessKey = arg.substr(13);
        } else if (arg.rfind("--secret-access-key=", 0) == 0) {
            args.config.secretAccessKey = arg.substr(20);
        } else if (arg == "--object-key" || arg == "--path") {
            args.config.objectKey = requireValue(arg);
        } else if (arg.rfind("--object-key=", 0) == 0) {
            args.config.objectKey = arg.substr(13);
        } else if (arg.rfind("--path=", 0) == 0) {
            args.config.objectKey = arg.substr(7);
        } else if (arg == "--download-url") {
            args.downloadUrl = requireValue(arg);
        } else if (arg.rfind("--download-url=", 0) == 0) {
            args.downloadUrl = arg.substr(15);
        } else if (arg == "--upload-url") {
            args.uploadUrl = requireValue(arg);
        } else if (arg.rfind("--upload-url=", 0) == 0) {
            args.uploadUrl = arg.substr(13);
        } else if (arg == "--username") {
            args.webDavUsername = requireValue(arg);
        } else if (arg.rfind("--username=", 0) == 0) {
            args.webDavUsername = arg.substr(11);
        } else if (arg == "--remote-password") {
            args.webDavPassword = requireValue(arg);
        } else if (arg.rfind("--remote-password=", 0) == 0) {
            args.webDavPassword = arg.substr(18);
        } else if (arg == "--device-id") {
            args.deviceId = requireValue(arg);
        } else if (arg.rfind("--device-id=", 0) == 0) {
            args.deviceId = arg.substr(12);
        } else if (arg == "--conflict-strategy") {
            args.conflictStrategy = requireValue(arg);
        } else if (arg.rfind("--conflict-strategy=", 0) == 0) {
            args.conflictStrategy = arg.substr(20);
        } else {
            throw std::invalid_argument("unknown sync option: " + arg);
        }
    }
    if (args.config.provider == ObjectSyncProvider::None) throw std::invalid_argument("--provider is required");
    if (args.config.provider == ObjectSyncProvider::S3Presigned) {
        if (args.downloadUrl.empty()) args.downloadUrl = args.config.customUrl;
        if (args.uploadUrl.empty()) args.uploadUrl = args.config.customUrl;
        if (args.downloadUrl.empty() || args.uploadUrl.empty()) {
            throw std::invalid_argument("s3-presigned sync requires --download-url and --upload-url");
        }
    }
    if (args.config.provider == ObjectSyncProvider::WebDav && args.config.endpoint.empty() && args.config.customUrl.empty()) {
        throw std::invalid_argument("webdav sync requires --endpoint or --custom-url");
    }
    if (args.deviceId.empty()) args.deviceId = "native-cli";
    if (args.conflictStrategy.empty()) args.conflictStrategy = "localWins";
    args.statePath = resolveSyncStatePath(args.vaultPath, args.statePath);
    return args;
}

VaultSnapshot loadSnapshotOrEmpty(const std::string& password, const std::string& path) {
    return decryptEnvelope(password, loadEnvelopeFile(path));
}

void saveSnapshot(const std::string& password, const std::string& path, const VaultSnapshot& snapshot) {
    saveEnvelopeFile(path, createEnvelope(password, snapshot));
}

void ensureParentDirectory(const fs::path& path);

std::map<std::string, std::string> readKeyValueFile(const fs::path& path) {
    std::map<std::string, std::string> values;
    std::ifstream in(path, std::ios::binary);
    if (!in) return values;
    std::string line;
    while (std::getline(in, line)) {
        const auto split = line.find('=');
        if (split == std::string::npos) continue;
        values[line.substr(0, split)] = line.substr(split + 1);
    }
    return values;
}

void writeKeyValueFile(const fs::path& path, const std::map<std::string, std::string>& values) {
    ensureParentDirectory(path);
    std::ofstream out(path, std::ios::binary | std::ios::trunc);
    if (!out) throw std::runtime_error("Unable to open state file for writing: " + path.string());
    for (const auto& [key, value] : values) out << key << "=" << value << "\n";
    if (!out) throw std::runtime_error("Unable to write state file: " + path.string());
}

void writeSingleLineFile(const fs::path& path, const std::string& value) {
    ensureParentDirectory(path);
    std::ofstream out(path, std::ios::binary | std::ios::trunc);
    if (!out) throw std::runtime_error("Unable to open state pointer for writing: " + path.string());
    out << value << "\n";
    if (!out) throw std::runtime_error("Unable to write state pointer: " + path.string());
}

SyncSettingsState loadSyncState(const SyncArgs& args) {
    auto values = readKeyValueFile(args.statePath);
    SyncSettingsState state;
    state.deviceId = values.count("deviceId") ? values["deviceId"] : args.deviceId;
    state.lastSyncRevision = values.count("lastSyncRevision") ? std::stoi(values["lastSyncRevision"]) : 0;
    state.hasLocalChanges = values.count("hasLocalChanges") ? values["hasLocalChanges"] != "false" : true;
    state.conflictStrategy = values.count("conflictStrategy") ? values["conflictStrategy"] : args.conflictStrategy;
    state.lastRemoteFingerprint = values.count("lastRemoteFingerprint") ? values["lastRemoteFingerprint"] : "";
    state.lastSyncStatus = values.count("lastSyncStatus") ? values["lastSyncStatus"] : "";
    state.lastSyncMessage = values.count("lastSyncMessage") ? values["lastSyncMessage"] : "";
    state.lastSyncAt = values.count("lastSyncAt") ? values["lastSyncAt"] : "";
    if (!args.deviceId.empty() && state.deviceId.empty()) state.deviceId = args.deviceId;
    if (!args.conflictStrategy.empty()) state.conflictStrategy = args.conflictStrategy;
    return state;
}

void saveSyncState(const SyncArgs& args, const SyncSettingsState& state) {
    writeKeyValueFile(args.statePath, {
        {"deviceId", state.deviceId},
        {"lastSyncRevision", std::to_string(state.lastSyncRevision)},
        {"hasLocalChanges", state.hasLocalChanges ? "true" : "false"},
        {"conflictStrategy", state.conflictStrategy},
        {"lastRemoteFingerprint", state.lastRemoteFingerprint},
        {"lastSyncStatus", state.lastSyncStatus},
        {"lastSyncMessage", state.lastSyncMessage},
        {"lastSyncAt", state.lastSyncAt},
    });
    if (args.statePath != defaultSyncStatePath(args.vaultPath)) {
        writeSingleLineFile(syncStatePointerPath(args.vaultPath), args.statePath);
    }
}

void markLocalChanges(const std::string& vaultPath) {
    const auto statePath = fs::path(resolveSyncStatePath(vaultPath, ""));
    auto values = readKeyValueFile(statePath);
    if (values.empty()) return;
    values["hasLocalChanges"] = "true";
    writeKeyValueFile(statePath, values);
}

HttpResult performHttp(const ObjectSyncRequest& request, const SyncArgs& args) {
    static CurlGlobal curlGlobal;
    CURL* curl = curl_easy_init();
    if (!curl) throw std::runtime_error("Unable to create HTTP client.");

    std::string body;
    HeaderAccumulator responseHeaders;
    curl_slist* headers = nullptr;
    try {
        curl_easy_setopt(curl, CURLOPT_URL, request.objectUrl.c_str());
        curl_easy_setopt(curl, CURLOPT_CUSTOMREQUEST, request.method.c_str());
        curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, curlWriteCallback);
        curl_easy_setopt(curl, CURLOPT_WRITEDATA, &body);
        curl_easy_setopt(curl, CURLOPT_HEADERFUNCTION, curlHeaderCallback);
        curl_easy_setopt(curl, CURLOPT_HEADERDATA, &responseHeaders);
        curl_easy_setopt(curl, CURLOPT_CONNECTTIMEOUT, 12L);
        curl_easy_setopt(curl, CURLOPT_TIMEOUT, 30L);
        curl_easy_setopt(curl, CURLOPT_NOSIGNAL, 1L);

        if (request.method == "HEAD") {
            curl_easy_setopt(curl, CURLOPT_NOBODY, 1L);
        }
        if (!request.body.empty() || request.method == "PUT") {
            curl_easy_setopt(curl, CURLOPT_POSTFIELDS, request.body.data());
            curl_easy_setopt(curl, CURLOPT_POSTFIELDSIZE, static_cast<long>(request.body.size()));
        }
        for (const auto& [key, value] : request.headers) {
            headers = curl_slist_append(headers, (key + ": " + value).c_str());
        }
        if (headers) curl_easy_setopt(curl, CURLOPT_HTTPHEADER, headers);
        if (request.provider == ObjectSyncProvider::WebDav &&
            (!args.webDavUsername.empty() || !args.webDavPassword.empty())) {
            curl_easy_setopt(curl, CURLOPT_HTTPAUTH, CURLAUTH_BASIC);
            curl_easy_setopt(curl, CURLOPT_USERNAME, args.webDavUsername.c_str());
            curl_easy_setopt(curl, CURLOPT_PASSWORD, args.webDavPassword.c_str());
        }

        const auto code = curl_easy_perform(curl);
        if (code != CURLE_OK) {
            throw std::runtime_error(std::string("HTTP transport failed: ") + curl_easy_strerror(code));
        }
        long statusCode = 0;
        curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &statusCode);
        if (headers) curl_slist_free_all(headers);
        curl_easy_cleanup(curl);
        return HttpResult{statusCode, body, syncFingerprint(responseHeaders)};
    } catch (...) {
        if (headers) curl_slist_free_all(headers);
        curl_easy_cleanup(curl);
        throw;
    }
}

ObjectSyncRequest presignedRequest(const std::string& url, const std::string& method, const std::string& body = "") {
    ObjectSyncRequest request;
    request.provider = ObjectSyncProvider::S3Presigned;
    request.objectUrl = url;
    request.method = method;
    request.body = body;
    if (method == "PUT") request.headers["Content-Type"] = "application/json";
    return request;
}

ObjectSyncRequest remoteRequest(const SyncArgs& args, const std::string& method, const std::string& body = "") {
    if (args.config.provider == ObjectSyncProvider::S3Presigned) {
        return presignedRequest(method == "PUT" ? args.uploadUrl : args.downloadUrl, method, body);
    }
    return buildObjectSyncSignedRequest(args.config, method, body);
}

HttpResult remoteDownload(const SyncArgs& args) {
    auto request = remoteRequest(args, "GET");
    return performHttp(request, args);
}

HttpResult remoteUpload(const SyncArgs& args, const std::string& payload) {
    auto request = remoteRequest(args, "PUT", payload);
    return performHttp(request, args);
}

std::string timestampForFileName(std::time_t now = std::time(nullptr)) {
    std::tm tm{};
#if defined(_WIN32)
    gmtime_s(&tm, &now);
#else
    gmtime_r(&now, &tm);
#endif
    std::ostringstream out;
    out << std::put_time(&tm, "%Y%m%d-%H%M%S");
    return out.str();
}

fs::path siblingDirectory(const std::string& vaultPath, const std::string& directoryName) {
    const auto parent = fs::path(vaultPath).parent_path();
    return (parent.empty() ? fs::path(".") : parent) / directoryName;
}

fs::path backupDirectoryFor(const BackupArgs& args) {
    return args.backupDir.empty() ? siblingDirectory(args.vaultPath, "backups") : fs::path(args.backupDir);
}

fs::path exportDirectoryFor(const ExportSnapshotArgs& args) {
    return args.exportDir.empty() ? siblingDirectory(args.vaultPath, "exports") : fs::path(args.exportDir);
}

void ensureDirectory(const fs::path& directory) {
    if (directory.empty()) return;
    fs::create_directories(directory);
    if (!fs::is_directory(directory)) throw std::runtime_error("Unable to create directory: " + directory.string());
}

void ensureParentDirectory(const fs::path& path) {
    const auto parent = path.parent_path();
    if (!parent.empty()) ensureDirectory(parent);
}

bool allDigits(const std::string& value, std::size_t start, std::size_t count) {
    if (start + count > value.size()) return false;
    for (std::size_t index = start; index < start + count; ++index) {
        if (!std::isdigit(static_cast<unsigned char>(value[index]))) return false;
    }
    return true;
}

bool isBackupFileName(const std::string& name) {
    return name.size() == 26 &&
           name.rfind("vault-", 0) == 0 &&
           name[14] == '-' &&
           name.compare(21, 5, ".json") == 0 &&
           allDigits(name, 6, 8) &&
           allDigits(name, 15, 6);
}

std::vector<fs::path> listBackupPaths(const fs::path& backupDir) {
    ensureDirectory(backupDir);
    std::vector<fs::path> backups;
    for (const auto& entry : fs::directory_iterator(backupDir)) {
        if (entry.is_regular_file() && isBackupFileName(entry.path().filename().string())) {
            backups.push_back(entry.path());
        }
    }
    std::sort(backups.begin(), backups.end(), [](const fs::path& left, const fs::path& right) {
        return left.filename().string() > right.filename().string();
    });
    return backups;
}

void pruneBackups(const fs::path& backupDir) {
    const auto backups = listBackupPaths(backupDir);
    for (std::size_t index = kBackupRetentionCount; index < backups.size(); ++index) {
        fs::remove(backups[index]);
    }
}

fs::path selectedBackupPath(const BackupArgs& args) {
    const auto backupDir = backupDirectoryFor(args);
    if (args.backupName.empty() || args.backupName == "latest") {
        const auto backups = listBackupPaths(backupDir);
        if (backups.empty()) throw std::runtime_error("No local backup is available.");
        return backups.front();
    }
    const auto sanitizedName = fs::path(args.backupName).filename().string();
    if (!isBackupFileName(sanitizedName)) throw std::invalid_argument("Backup file is not available.");
    const auto backupPath = backupDir / sanitizedName;
    if (!fs::is_regular_file(backupPath)) throw std::runtime_error("Backup file is not available.");
    return backupPath;
}

std::string readTextFile(const fs::path& path) {
    std::ifstream in(path, std::ios::binary);
    if (!in) throw std::runtime_error("Unable to open file for reading: " + path.string());
    std::ostringstream buffer;
    buffer << in.rdbuf();
    if (!in.good() && !in.eof()) throw std::runtime_error("Unable to read file: " + path.string());
    return buffer.str();
}

void writeTextFile(const fs::path& path, const std::string& text) {
    ensureParentDirectory(path);
    std::ofstream out(path, std::ios::binary | std::ios::trunc);
    if (!out) throw std::runtime_error("Unable to open file for writing: " + path.string());
    out << text;
    if (!out) throw std::runtime_error("Unable to write file: " + path.string());
}

void printCounts(const VaultSnapshot& snapshot) {
    const auto deleted = std::count_if(snapshot.entries.begin(), snapshot.entries.end(), [](const auto& entry) {
        return entry.isDeleted;
    });
    std::cout << "entries=" << (snapshot.entries.size() - static_cast<std::size_t>(deleted))
              << " deletedEntries=" << deleted
              << " categories=" << snapshot.categories.size()
              << " categoryTemplates=" << snapshot.categoryTemplates.size()
              << " tags=" << snapshot.tags.size() << "\n";
}

void rebuildTaxonomy(VaultSnapshot& snapshot) {
    auto categories = snapshot.categories;
    for (const auto& templateEntry : snapshot.categoryTemplates) {
        if (!templateEntry.category.empty()) categories.push_back(templateEntry.category);
    }
    const auto entryCategories = rebuildCategories(snapshot.entries);
    categories.insert(categories.end(), entryCategories.begin(), entryCategories.end());
    std::sort(categories.begin(), categories.end());
    categories.erase(std::unique(categories.begin(), categories.end()), categories.end());
    snapshot.categories = categories;

    auto tags = snapshot.tags;
    const auto entryTags = rebuildTags(snapshot.entries);
    tags.insert(tags.end(), entryTags.begin(), entryTags.end());
    std::sort(tags.begin(), tags.end());
    tags.erase(std::unique(tags.begin(), tags.end()), tags.end());
    snapshot.tags = tags;
    for (const auto& category : snapshot.categories) {
        bool exists = false;
        for (const auto& templateEntry : snapshot.categoryTemplates) {
            if (templateEntry.category == category) {
                exists = true;
                break;
            }
        }
        if (!exists) snapshot.categoryTemplates.push_back(CategoryTemplate{category, defaultCategoryFields()});
    }
    std::sort(snapshot.categoryTemplates.begin(), snapshot.categoryTemplates.end(), [](const auto& left, const auto& right) {
        return left.category < right.category;
    });
}

void printEntryLine(const VaultEntry& entry, bool showSecret) {
    std::cout << entry.id
              << " | " << entry.type
              << " | " << entry.label
              << " | category=" << entry.category
              << " | username=" << entry.username
              << " | secret=" << maskedSecret(entry.secret, showSecret);
    if (!entry.tags.empty()) {
        std::cout << " | tags=";
        for (std::size_t index = 0; index < entry.tags.size(); ++index) {
            if (index > 0) std::cout << ",";
            std::cout << entry.tags[index];
        }
    }
    std::cout << "\n";
}

std::string entryJsonForDisplay(const VaultEntry& entry, bool showSecret) {
    VaultEntry copy = entry;
    if (!showSecret) {
        copy.secret = maskedSecret(copy.secret, false);
        copy.payloadJson.clear();
    }
    VaultSnapshot snapshot;
    snapshot.entries.push_back(copy);
    rebuildTaxonomy(snapshot);
    return serializeSnapshotJson(snapshot);
}

void printCategoryTemplate(int argc, char** argv, const char* defaultVaultPath) {
    const auto args = parseCategoryArgs(argc, argv, 2, 3, defaultVaultPath, false);
    VaultSnapshot snapshot;
    const auto fields = fieldsForCli(args.hasPreset, args.preset, args.customFields);
    if (!addCategory(snapshot, args.name, fields)) throw std::invalid_argument("category name is required");
    std::cout << serializeSnapshotJson(snapshot) << "\n";
}

void initializeVault(int argc, char** argv, const char* defaultVaultPath) {
    if (argc < 3) throw std::invalid_argument("password is required");
    const auto options = parseVaultOption(argc, argv, 3, defaultVaultPath);
    VaultSnapshot snapshot;
    saveSnapshot(argv[2], options.vaultPath, snapshot);
    std::cout << "Encrypted vault written to " << options.vaultPath << "\n";
}

void printStatus(int argc, char** argv, const char* defaultVaultPath) {
    if (argc < 3) throw std::invalid_argument("password is required");
    const auto options = parseVaultOption(argc, argv, 3, defaultVaultPath);
    printCounts(loadSnapshotOrEmpty(argv[2], options.vaultPath));
}

void addCategoryToVault(int argc, char** argv, const char* defaultVaultPath) {
    if (argc < 4) throw std::invalid_argument("password and category name are required");
    const std::string password = argv[2];
    const auto args = parseCategoryArgs(argc, argv, 3, 4, defaultVaultPath, true);
    auto snapshot = loadSnapshotOrEmpty(password, args.vaultPath);
    const auto fields = fieldsForCli(args.hasPreset, args.preset, args.customFields);
    if (!addCategory(snapshot, args.name, fields)) throw std::invalid_argument("category already exists or is empty");
    saveSnapshot(password, args.vaultPath, snapshot);
    markLocalChanges(args.vaultPath);
    std::cout << "Category added to " << args.vaultPath << "\n";
}

void addEntryToVault(int argc, char** argv, const char* defaultVaultPath) {
    if (argc < 3) throw std::invalid_argument("password is required");
    const std::string password = argv[2];
    const auto args = parseEntryArgs(argc, argv, 3, defaultVaultPath);
    auto snapshot = loadSnapshotOrEmpty(password, args.vaultPath);
    auto entry = makeEntry(args.label, args.type, args.username, args.secret);
    entry.category = args.category;
    entry.tags = args.tags;
    entry.notes = args.notes;
    entry.customFields = args.customFields;
    snapshot.entries.push_back(entry);
    rebuildTaxonomy(snapshot);
    saveSnapshot(password, args.vaultPath, snapshot);
    markLocalChanges(args.vaultPath);
    std::cout << "Entry added " << entry.id << " to " << args.vaultPath << "\n";
}

void listEntries(int argc, char** argv, const char* defaultVaultPath) {
    if (argc < 3) throw std::invalid_argument("password is required");
    const std::string password = argv[2];
    const auto args = parseListArgs(argc, argv, 3, defaultVaultPath);
    const auto snapshot = loadSnapshotOrEmpty(password, args.vaultPath);
    const auto entries = filterEntries(snapshot.entries, args.query, args.type);
    std::cout << "matches=" << entries.size() << "\n";
    for (const auto& entry : entries) printEntryLine(entry, args.showSecret);
}

void showEntry(int argc, char** argv, const char* defaultVaultPath) {
    if (argc < 4) throw std::invalid_argument("password and entry id are required");
    const std::string password = argv[2];
    const std::string id = argv[3];
    const auto args = parseShowEntryArgs(argc, argv, 4, defaultVaultPath);
    const auto snapshot = loadSnapshotOrEmpty(password, args.vaultPath);
    for (const auto& entry : snapshot.entries) {
        if (entry.id == id) {
            std::cout << entryJsonForDisplay(entry, args.showSecret) << "\n";
            return;
        }
    }
    throw std::invalid_argument("entry not found");
}

void deleteEntry(int argc, char** argv, const char* defaultVaultPath) {
    if (argc < 4) throw std::invalid_argument("password and entry id are required");
    const std::string password = argv[2];
    const std::string id = argv[3];
    const auto options = parseVaultOption(argc, argv, 4, defaultVaultPath);
    auto snapshot = loadSnapshotOrEmpty(password, options.vaultPath);
    for (auto& entry : snapshot.entries) {
        if (entry.id == id) {
            entry.isDeleted = true;
            entry.deletedAt = isoTimestamp();
            entry.updatedAt = entry.deletedAt;
            entry.updatedBy = "native-cli";
            entry.version["native-cli"] += 1;
            rebuildTaxonomy(snapshot);
            saveSnapshot(password, options.vaultPath, snapshot);
            markLocalChanges(options.vaultPath);
            std::cout << "Entry deleted " << id << "\n";
            return;
        }
    }
    throw std::invalid_argument("entry not found");
}

void backupVault(int argc, char** argv, const char* defaultVaultPath) {
    if (argc < 3) throw std::invalid_argument("password is required");
    const std::string password = argv[2];
    const auto args = parseBackupArgs(argc, argv, 3, defaultVaultPath, false);
    auto snapshot = loadSnapshotOrEmpty(password, args.vaultPath);
    const auto backupDir = backupDirectoryFor(args);
    ensureDirectory(backupDir);
    const auto backupPath = backupDir / ("vault-" + timestampForFileName() + ".json");
    fs::copy_file(fs::path(args.vaultPath), backupPath, fs::copy_options::overwrite_existing);
    pruneBackups(backupDir);
    snapshot.backupStatus = "Backup saved: " + backupPath.filename().string();
    saveSnapshot(password, args.vaultPath, snapshot);
    std::cout << snapshot.backupStatus << " (" << backupPath.string() << ")\n";
}

void listBackups(int argc, char** argv, const char* defaultVaultPath) {
    const auto args = parseBackupArgs(argc, argv, 2, defaultVaultPath, false);
    const auto backups = listBackupPaths(backupDirectoryFor(args));
    std::cout << "backups=" << backups.size() << "\n";
    for (const auto& backup : backups) {
        std::cout << backup.filename().string() << " | bytes=" << fs::file_size(backup) << "\n";
    }
}

void restoreBackup(int argc, char** argv, const char* defaultVaultPath) {
    if (argc < 3) throw std::invalid_argument("password is required");
    const std::string password = argv[2];
    const auto args = parseBackupArgs(argc, argv, 3, defaultVaultPath, true);
    const auto backupPath = selectedBackupPath(args);
    auto snapshot = decryptEnvelope(password, loadEnvelopeFile(backupPath.string()));
    fs::copy_file(backupPath, fs::path(args.vaultPath), fs::copy_options::overwrite_existing);
    snapshot.backupStatus = "Restored backup: " + backupPath.filename().string();
    saveSnapshot(password, args.vaultPath, snapshot);
    markLocalChanges(args.vaultPath);
    std::cout << snapshot.backupStatus << "\n";
}

void exportSnapshot(int argc, char** argv, const char* defaultVaultPath) {
    if (argc < 3) throw std::invalid_argument("password is required");
    const std::string password = argv[2];
    const auto args = parseExportSnapshotArgs(argc, argv, 3, defaultVaultPath);
    auto snapshot = loadSnapshotOrEmpty(password, args.vaultPath);
    rebuildTaxonomy(snapshot);
    const auto exportPath = args.outPath.empty()
        ? exportDirectoryFor(args) / ("vault-export-" + timestampForFileName() + ".json")
        : fs::path(args.outPath);
    writeTextFile(exportPath, serializeSnapshotJson(snapshot));
    std::cout << "Export saved: " << exportPath.string() << "\n";
}

void importSnapshot(int argc, char** argv, const char* defaultVaultPath) {
    if (argc < 3) throw std::invalid_argument("password is required");
    const std::string password = argv[2];
    const auto args = parseImportSnapshotArgs(argc, argv, 3, defaultVaultPath);
    (void)loadSnapshotOrEmpty(password, args.vaultPath);
    auto snapshot = parseSnapshotJson(readTextFile(fs::path(args.inPath)));
    rebuildTaxonomy(snapshot);
    saveSnapshot(password, args.vaultPath, snapshot);
    markLocalChanges(args.vaultPath);
    const auto active = std::count_if(snapshot.entries.begin(), snapshot.entries.end(), [](const auto& entry) {
        return !entry.isDeleted;
    });
    std::cout << "Imported " << active << " active entries.\n";
}

void synchronizeVault(int argc, char** argv, const char* defaultVaultPath) {
    if (argc < 3) throw std::invalid_argument("password is required");
    const std::string password = argv[2];
    const auto args = parseSyncArgs(argc, argv, 3, defaultVaultPath);
    auto localSnapshot = loadSnapshotOrEmpty(password, args.vaultPath);
    auto settings = loadSyncState(args);

    const auto download = remoteDownload(args);
    if (!isHttpDownloadSuccess(download.statusCode)) {
        throw std::runtime_error("Sync download failed with status " + std::to_string(download.statusCode) + ".");
    }
    const auto remoteBody = download.statusCode == 404 ? "" : download.body;
    auto result = synchronizeSnapshots(localSnapshot, settings, remoteBody, download.fingerprint);

    if (result.uploaded) {
        const auto upload = remoteUpload(args, result.uploadPayloadJson);
        if (!isHttpSuccess(upload.statusCode)) {
            throw std::runtime_error("Sync upload failed with status " + std::to_string(upload.statusCode) + ".");
        }
    }

    result.snapshot.syncStatus = result.settings.lastSyncStatus.empty() ? "Synced" : result.settings.lastSyncStatus;
    saveSnapshot(password, args.vaultPath, result.snapshot);
    saveSyncState(args, result.settings);
    std::cout << "Sync complete"
              << " revision=" << result.settings.lastSyncRevision
              << " uploaded=" << (result.uploaded ? "true" : "false")
              << " appliedRemote=" << (result.appliedRemote ? "true" : "false")
              << " conflicts=" << result.stats.conflicts
              << " message=\"" << result.settings.lastSyncMessage << "\"\n";
}

void selfTest() {
    VaultSnapshot snapshot;
    snapshot.entries.push_back(makeEntry("Self Test", "credential", "self@example.com", "secret"));
    auto envelope = createEnvelope("password", snapshot);
    auto loaded = decryptEnvelope("password", envelope);
    std::cout << loaded.syncStatus << "\n";
}

} // namespace

int runNativeCli(int argc, char** argv, const char* platformName, const char* defaultVaultPath) {
    try {
        if (argc < 2) {
            printUsage(platformName, defaultVaultPath);
            return 0;
        }
        const std::string command = argv[1];
        if (command == "init") {
            initializeVault(argc, argv, defaultVaultPath);
            return 0;
        }
        if (command == "status") {
            printStatus(argc, argv, defaultVaultPath);
            return 0;
        }
        if (command == "add-category") {
            addCategoryToVault(argc, argv, defaultVaultPath);
            return 0;
        }
        if (command == "add-entry") {
            addEntryToVault(argc, argv, defaultVaultPath);
            return 0;
        }
        if (command == "list") {
            listEntries(argc, argv, defaultVaultPath);
            return 0;
        }
        if (command == "show-entry") {
            showEntry(argc, argv, defaultVaultPath);
            return 0;
        }
        if (command == "delete-entry") {
            deleteEntry(argc, argv, defaultVaultPath);
            return 0;
        }
        if (command == "backup") {
            backupVault(argc, argv, defaultVaultPath);
            return 0;
        }
        if (command == "list-backups") {
            listBackups(argc, argv, defaultVaultPath);
            return 0;
        }
        if (command == "restore-backup") {
            restoreBackup(argc, argv, defaultVaultPath);
            return 0;
        }
        if (command == "export-snapshot") {
            exportSnapshot(argc, argv, defaultVaultPath);
            return 0;
        }
        if (command == "import-snapshot") {
            importSnapshot(argc, argv, defaultVaultPath);
            return 0;
        }
        if (command == "sync") {
            synchronizeVault(argc, argv, defaultVaultPath);
            return 0;
        }
        if (command == "category") {
            printCategoryTemplate(argc, argv, defaultVaultPath);
            return 0;
        }
        if (command == "totp" && argc == 4) {
            std::cout << generateTotp(argv[2], std::stoull(argv[3])) << "\n";
            return 0;
        }
        if (command == "self-test") {
            selfTest();
            return 0;
        }
        printUsage(platformName, defaultVaultPath);
        return 1;
    } catch (const std::exception& error) {
        std::cerr << error.what() << "\n";
        return 2;
    }
}

} // namespace pm
