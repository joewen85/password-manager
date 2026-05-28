#include "vault_core.hpp"

#include <fstream>
#include <iostream>
#include <stdexcept>

namespace {

void printUsage() {
    std::cout << "Password Manager Windows Native\n"
              << "Commands:\n"
              << "  init <password>             Create an encrypted vault smoke-test envelope\n"
              << "  totp <base32-secret> <unix> Generate a TOTP code\n"
              << "  self-test                   Run a small runtime check\n";
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
