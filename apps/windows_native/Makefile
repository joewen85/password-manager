CXX ?= clang++
OPENSSL_PREFIX ?= /opt/homebrew/opt/openssl@3
CXXFLAGS ?= -std=c++17 -Wall -Wextra -Wpedantic -O2
PM_CPPFLAGS := -I$(OPENSSL_PREFIX)/include
PM_LDFLAGS := -L$(OPENSSL_PREFIX)/lib
LDLIBS ?= -lcrypto

BUILD_DIR := build
APP := $(BUILD_DIR)/password-manager-windows-core
TESTS := $(BUILD_DIR)/windows-native-tests
CORE_SRC := src/vault_core.cpp

.PHONY: all test clean

all: $(APP)

$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

$(APP): $(BUILD_DIR) $(CORE_SRC) src/main.cpp src/vault_core.hpp
	$(CXX) $(CXXFLAGS) $(PM_CPPFLAGS) $(CORE_SRC) src/main.cpp $(PM_LDFLAGS) $(LDLIBS) -o $@

$(TESTS): $(BUILD_DIR) $(CORE_SRC) tests/vault_core_tests.cpp src/vault_core.hpp
	$(CXX) $(CXXFLAGS) $(PM_CPPFLAGS) $(CORE_SRC) tests/vault_core_tests.cpp $(PM_LDFLAGS) $(LDLIBS) -o $@

test: $(TESTS)
	$(TESTS)

clean:
	rm -rf $(BUILD_DIR)
