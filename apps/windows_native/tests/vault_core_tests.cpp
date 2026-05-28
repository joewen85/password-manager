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

    std::cout << "windows-native core tests passed\n";
    return 0;
}
