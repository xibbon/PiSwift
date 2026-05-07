# PiSwift Makefile
#
# Common targets:
#   make build         # release build of pi-coding-agent + the extension SDK
#   make install       # install pi-coding-agent + extension SDK under PREFIX
#   make uninstall     # remove an installation under PREFIX
#   make run           # debug run via `swift run`
#   make clean         # delete .build/

PREFIX        ?= $(HOME)/.local
BIN_DIR        = $(PREFIX)/bin
LIB_DIR        = $(PREFIX)/lib/pi
TRIPLE        := $(shell uname -m)-apple-macosx
BUILD_DIR     := .build/$(TRIPLE)/release
MODULES_SRC   := $(BUILD_DIR)/Modules
DYLIB_SRC     := $(BUILD_DIR)/libPiExtensionSDK.dylib
BIN_SRC       := $(BUILD_DIR)/pi-coding-agent

.PHONY: run build install uninstall clean print-paths

run:
	swift run pi-coding-agent

build:
	swift build -c release --product pi-coding-agent
	swift build -c release --product PiExtensionSDK

# Install layout (FHS-style):
#   $(BIN_DIR)/pi-coding-agent
#   $(LIB_DIR)/libPiExtensionSDK.dylib
#   $(LIB_DIR)/Modules/<all .swiftmodule, .swiftdoc, .abi.json files>
#
# ExtensionCompiler.resolveSDKPaths() finds this via the `<bin>/../lib/pi/` probe.
# Extensions written by the user are then compiled against $(LIB_DIR)/Modules and
# linked with `-undefined dynamic_lookup` against the host process at runtime.
install: build
	@if [ ! -f "$(DYLIB_SRC)" ]; then \
		echo "error: $(DYLIB_SRC) not found — did 'swift build' produce it?"; exit 1; \
	fi
	@if [ ! -d "$(MODULES_SRC)" ]; then \
		echo "error: $(MODULES_SRC) not found — did 'swift build' produce it?"; exit 1; \
	fi
	@install -d "$(BIN_DIR)" "$(LIB_DIR)/Modules"
	@install -m 0755 "$(BIN_SRC)" "$(BIN_DIR)/pi-coding-agent"
	@install -m 0755 "$(DYLIB_SRC)" "$(LIB_DIR)/libPiExtensionSDK.dylib"
	@cp "$(MODULES_SRC)"/*.swiftmodule "$(LIB_DIR)/Modules/" 2>/dev/null || true
	@cp "$(MODULES_SRC)"/*.swiftdoc     "$(LIB_DIR)/Modules/" 2>/dev/null || true
	@cp "$(MODULES_SRC)"/*.abi.json     "$(LIB_DIR)/Modules/" 2>/dev/null || true
	@cp "$(MODULES_SRC)"/*.swiftsourceinfo "$(LIB_DIR)/Modules/" 2>/dev/null || true
	@echo
	@echo "Installed:"
	@echo "  $(BIN_DIR)/pi-coding-agent"
	@echo "  $(LIB_DIR)/libPiExtensionSDK.dylib"
	@echo "  $(LIB_DIR)/Modules/  (`ls -1 "$(LIB_DIR)/Modules" | wc -l | tr -d ' '` files)"
	@echo
	@echo "Make sure $(BIN_DIR) is on your PATH."
	@echo "Drop extensions into ~/.pi/agent/extensions/*.swift and run /reload from the TUI."

uninstall:
	@rm -f "$(BIN_DIR)/pi-coding-agent"
	@rm -rf "$(LIB_DIR)"
	@echo "Removed $(BIN_DIR)/pi-coding-agent and $(LIB_DIR)"

clean:
	swift package clean
	rm -rf .build

# For debugging: show where install would place things.
print-paths:
	@echo "BIN_DIR=$(BIN_DIR)"
	@echo "LIB_DIR=$(LIB_DIR)"
	@echo "BUILD_DIR=$(BUILD_DIR)"
	@echo "DYLIB_SRC=$(DYLIB_SRC)"
	@echo "MODULES_SRC=$(MODULES_SRC)"
