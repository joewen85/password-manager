#include "vault_core.hpp"

#include <fstream>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>

namespace {

void printUsage() {
    std::cout << "Password Manager Windows Native\n"
              << "Commands:\n"
              << "  init <password>             Create an encrypted vault smoke-test envelope\n"
              << "  category <name> [--preset server|service|account] [--field <name>]...\n"
              << "                              Print category template JSON with custom fields\n"
              << "  totp <base32-secret> <unix> Generate a TOTP code\n"
              << "  self-test                   Run a small runtime check\n";
}

pm::CategoryTypePreset parsePreset(const std::string& value) {
    if (value == "server") return pm::CategoryTypePreset::Server;
    if (value == "service") return pm::CategoryTypePreset::Service;
    if (value == "account") return pm::CategoryTypePreset::Account;
    throw std::invalid_argument("preset must be server, service, or account");
}

void printCategoryTemplate(int argc, char** argv) {
    if (argc < 3) throw std::invalid_argument("category name is required");
    std::string name = argv[2];
    std::vector<std::string> customFields;
    pm::CategoryTypePreset preset = pm::CategoryTypePreset::Account;
    bool hasPreset = false;
    for (int i = 3; i < argc; ++i) {
        const std::string arg = argv[i];
        if (arg == "--preset") {
            if (++i >= argc) throw std::invalid_argument("--preset requires a value");
            preset = parsePreset(argv[i]);
            hasPreset = true;
        } else if (arg.rfind("--preset=", 0) == 0) {
            preset = parsePreset(arg.substr(9));
            hasPreset = true;
        } else if (arg == "--field") {
            if (++i >= argc) throw std::invalid_argument("--field requires a value");
            customFields.push_back(argv[i]);
        } else if (arg.rfind("--field=", 0) == 0) {
            customFields.push_back(arg.substr(8));
        } else {
            throw std::invalid_argument("unknown category option: " + arg);
        }
    }

    pm::VaultSnapshot snapshot;
    const bool added = hasPreset
        ? pm::addCategory(snapshot, name, preset, customFields)
        : pm::addCategory(snapshot, name, pm::categoryFieldsWithCustom(customFields));
    if (!added) throw std::invalid_argument("category name is required");
    std::cout << pm::serializeSnapshotJson(snapshot) << "\n";
}

} // namespace

int main(int argc, char** argv) {
    try {
        if (argc < 2) {
            printUsage();
            return 0;
        }
        std::string command = argv[1];
        if (command == "init" && argc == 3) {
            pm::VaultSnapshot snapshot;
            snapshot.entries.push_back(pm::makeEntry("Example Login", "credential", "user@example.com", "secret"));
            auto envelope = pm::createEnvelope(argv[2], snapshot);
            std::ofstream out("vault-windows-native.envelope");
            out << "schemaVersion=" << envelope.schemaVersion << "\n"
                << "salt=" << envelope.masterKeyRecord.saltBase64 << "\n"
                << "iterations=" << envelope.masterKeyRecord.iterations << "\n"
                << "verifier=" << envelope.masterKeyRecord.verifierBase64 << "\n"
                << "nonce=" << envelope.encryptedVault.nonceBase64 << "\n"
                << "ciphertext=" << envelope.encryptedVault.ciphertextBase64 << "\n"
                << "mac=" << envelope.encryptedVault.macBase64 << "\n";
            std::cout << "Encrypted vault smoke-test envelope written to vault-windows-native.envelope\n";
            return 0;
        }
        if (command == "totp" && argc == 4) {
            std::cout << pm::generateTotp(argv[2], std::stoull(argv[3])) << "\n";
            return 0;
        }
        if (command == "category") {
            printCategoryTemplate(argc, argv);
            return 0;
        }
        if (command == "self-test") {
            pm::VaultSnapshot snapshot;
            snapshot.entries.push_back(pm::makeEntry("Self Test", "credential", "self@example.com", "secret"));
            auto envelope = pm::createEnvelope("password", snapshot);
            auto loaded = pm::decryptEnvelope("password", envelope);
            std::cout << loaded.syncStatus << "\n";
            return 0;
        }
        printUsage();
        return 1;
    } catch (const std::exception& error) {
        std::cerr << error.what() << "\n";
        return 2;
    }
}
