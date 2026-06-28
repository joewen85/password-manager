CXX ?= clang++
OPENSSL_PREFIX ?= /opt/homebrew/opt/openssl@3
CXXFLAGS ?= -std=c++17 -Wall -Wextra -Wpedantic -O2
NATIVE_CORE_DIR := ../native_core
PM_CPPFLAGS := -I$(OPENSSL_PREFIX)/include -I$(NATIVE_CORE_DIR)/src
PM_LDFLAGS := -L$(OPENSSL_PREFIX)/lib
LDLIBS ?= -lcrypto

BUILD_DIR := build
APP := $(BUILD_DIR)/password-manager-linux
TESTS := $(BUILD_DIR)/linux-native-tests
CORE_SRC := $(NATIVE_CORE_DIR)/src/vault_core.cpp
CLI_SRC := $(NATIVE_CORE_DIR)/src/vault_cli.cpp
CORE_HEADER := $(NATIVE_CORE_DIR)/src/vault_core.hpp
CLI_HEADER := $(NATIVE_CORE_DIR)/src/vault_cli.hpp
CORE_TESTS := $(NATIVE_CORE_DIR)/tests/vault_core_tests.cpp

.PHONY: all test clean

all: $(APP)

$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

$(APP): $(BUILD_DIR) $(CORE_SRC) $(CLI_SRC) $(CORE_HEADER) $(CLI_HEADER) src/main.cpp
	$(CXX) $(CXXFLAGS) $(PM_CPPFLAGS) $(CORE_SRC) $(CLI_SRC) src/main.cpp $(PM_LDFLAGS) $(LDLIBS) -o $@

$(TESTS): $(BUILD_DIR) $(CORE_SRC) $(CORE_HEADER) $(CORE_TESTS)
	$(CXX) $(CXXFLAGS) $(PM_CPPFLAGS) $(CORE_SRC) $(CORE_TESTS) $(PM_LDFLAGS) $(LDLIBS) -o $@

test: $(TESTS) $(APP)
	$(TESTS)
	bash $(NATIVE_CORE_DIR)/tests/vault_cli_smoke.sh $(APP)

clean:
	rm -rf $(BUILD_DIR)
