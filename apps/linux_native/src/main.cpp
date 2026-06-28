#include "vault_cli.hpp"

int main(int argc, char** argv) {
    return pm::runNativeCli(argc, argv, "Linux", "vault-linux-native.envelope");
}
