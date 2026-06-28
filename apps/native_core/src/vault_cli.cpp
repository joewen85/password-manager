#include "vault_cli.hpp"

#include "vault_core.hpp"

#include <iostream>
#include <algorithm>
#include <cctype>
#include <ctime>
#include <filesystem>
#include <fstream>
#include <iomanip>
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

std::string maskedSecret(const std::string& value, bool showSecret) {
    if (showSecret) return value;
    return value.empty() ? "" : "******";
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

VaultSnapshot loadSnapshotOrEmpty(const std::string& password, const std::string& path) {
    return decryptEnvelope(password, loadEnvelopeFile(path));
}

void saveSnapshot(const std::string& password, const std::string& path, const VaultSnapshot& snapshot) {
    saveEnvelopeFile(path, createEnvelope(password, snapshot));
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
    const auto active = std::count_if(snapshot.entries.begin(), snapshot.entries.end(), [](const auto& entry) {
        return !entry.isDeleted;
    });
    std::cout << "Imported " << active << " active entries.\n";
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
