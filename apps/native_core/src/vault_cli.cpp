#include "vault_cli.hpp"

#include "vault_core.hpp"

#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>

namespace pm {
namespace {

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
              << "  add-category <password> <name> [--preset server|service|account] [--field <name>]... [--vault <path>]\n"
              << "                              Persist a category template in the encrypted vault\n"
              << "  category <name> [--preset server|service|account] [--field <name>]...\n"
              << "                              Print category template JSON without saving\n"
              << "  totp <base32-secret> <unix> Generate a TOTP code\n"
              << "  self-test                   Run a small runtime check\n"
              << "\nDefault vault: " << defaultVaultPath << "\n";
}

CategoryTypePreset parsePreset(const std::string& value) {
    if (value == "server") return CategoryTypePreset::Server;
    if (value == "service") return CategoryTypePreset::Service;
    if (value == "account") return CategoryTypePreset::Account;
    throw std::invalid_argument("preset must be server, service, or account");
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
        if (arg == "--preset") {
            if (++i >= argc) throw std::invalid_argument("--preset requires a value");
            args.preset = parsePreset(argv[i]);
            args.hasPreset = true;
        } else if (arg.rfind("--preset=", 0) == 0) {
            args.preset = parsePreset(arg.substr(9));
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

VaultSnapshot loadSnapshotOrEmpty(const std::string& password, const std::string& path) {
    return decryptEnvelope(password, loadEnvelopeFile(path));
}

void saveSnapshot(const std::string& password, const std::string& path, const VaultSnapshot& snapshot) {
    saveEnvelopeFile(path, createEnvelope(password, snapshot));
}

void printCounts(const VaultSnapshot& snapshot) {
    std::cout << "entries=" << snapshot.entries.size()
              << " categories=" << snapshot.categories.size()
              << " categoryTemplates=" << snapshot.categoryTemplates.size()
              << " tags=" << snapshot.tags.size() << "\n";
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
