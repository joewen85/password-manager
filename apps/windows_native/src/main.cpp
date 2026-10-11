#include "vault_cli.hpp"

int main(int argc, char** argv) {
    return pm::runNativeCli(argc, argv, "Windows", "vault-windows-native.envelope");
}
