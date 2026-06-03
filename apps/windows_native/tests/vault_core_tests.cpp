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
    entry.notes = "ip:1.2.3.4 owner:sre-team https://ops.example.com";
    snapshot.entries[0] = entry;
    assert(pm::filterEntries(snapshot.entries, "name:Production", "all").size() == 1);
    assert(pm::filterEntries(snapshot.entries, "ip:1.2.3.4", "all").size() == 1);
    assert(pm::filterEntries(snapshot.entries, "owner:sre-team", "all").size() == 1);
    assert(pm::filterEntries(snapshot.entries, "https://ops.example.com", "all").size() == 1);
    assert(pm::filterEntries(snapshot.entries, "tag:mail ip:1.2.3.4", "all").size() == 1);
    assert(pm::filterEntries(snapshot.entries, "ip:9.9.9.9", "all").empty());
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
    assert(merged.entries[1].label.find("Remote") != std::string::npos);

    pm::VaultEntry androidEntry = entry;
    androidEntry.id = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa";
    androidEntry.label = "Android";
    androidEntry.version = {{"android", 2}, {"macos", 1}};
    androidEntry.updatedBy = "android";
    pm::VaultEntry swiftEntry = entry;
    swiftEntry.id = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA";
    swiftEntry.label = "Swift";
    swiftEntry.version = {{"android", 1}, {"macos", 1}};
    swiftEntry.updatedBy = "macos";
    auto canonicalMerged = pm::mergeEntries({androidEntry}, {swiftEntry}, "localWins");
    assert(canonicalMerged.stats.conflicts == 0);
    assert(canonicalMerged.entries.size() == 1);
    assert(canonicalMerged.entries[0].id == "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa");
    assert(canonicalMerged.entries[0].label == "Android");

    pm::VaultSnapshot uppercaseSnapshot;
    uppercaseSnapshot.entries.push_back(swiftEntry);
    const auto serialized = pm::serializeSnapshotJson(uppercaseSnapshot);
    assert(serialized.find("AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA") == std::string::npos);
    assert(serialized.find("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa") != std::string::npos);

    std::cout << "windows-native core tests passed\n";
    return 0;
}
