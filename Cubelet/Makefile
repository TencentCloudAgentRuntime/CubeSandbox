APPS=cubelet cubecli
COVERAGE_PROFILE=coverage.profile
ROOT_DIR=$(shell pwd)
BUILD_DIR=$(ROOT_DIR)/build
PROTO=services/errorcode services/version services/snapshot services/cubebox services/runtime services/images services/nbi services/multimetadb services/volumeplugin types
PACK_DIR=$(BUILD_DIR)/cube-let

export GO111MODULE=on
export GOARCH ?= $(shell go env GOARCH)
export GOOS=linux
GO_BIN_DIR := $(shell if [ -n "$$(go env GOBIN)" ]; then printf "%s" "$$(go env GOBIN)"; else printf "%s/bin" "$$(go env GOPATH)"; fi)
PROTOC_VERSION := 5.28.3
PROTO_TOOLS_DIR := $(CURDIR)/.tools
PROTOC := $(PROTO_TOOLS_DIR)/protoc-$(PROTOC_VERSION)/bin/protoc
PROTO_TOOLS_BIN := $(PROTO_TOOLS_DIR)/bin
PROTOC_INCLUDE_FLAGS=-I=. -I=$(PROTO_TOOLS_DIR)/protoc-$(PROTOC_VERSION)/include
PROTOC_GO_FLAGS=--go_out=. --go_opt=paths=source_relative --go-grpc_out=. --go-grpc_opt=paths=source_relative
PROTO_DOC_FILES=$(shell python3 -c 'import glob; print(" ".join(sorted(glob.glob("api/**/*.proto", recursive=True))))')
export PATH := $(PROTO_TOOLS_BIN):$(GO_BIN_DIR):$(PATH)

ifeq ($(V),1)
Q =
msg =
else
Q = @
msg = @printf '  %-8s %s%s\n' "$(1)" "$(notdir $(2))" "$(if $(3), $(3))";
MAKEFLAGS += --no-print-directory
endif

PKG=github.com/tencentcloud/CubeSandbox/Cubelet/pkg

PWD = $(shell pwd)

# COVERAGE_PACKAGES is the coverage we care about.
COVERAGE_PACKAGES=$(shell go list ./... \
	| grep -v github.com/tencentcloud/CubeSandbox/Cubelet/api \
	| grep -v github.com/tencentcloud/CubeSandbox/Cubelet/cmd \
	| grep -v github.com/tencentcloud/CubeSandbox/Cubelet/shimlog \
	| grep -v github.com/tencentcloud/CubeSandbox/Cubelet/runtime \
	| grep -v /integration)

# Version — injected at build time via ldflags.
# Priority: env var CUBE_VERSION/CUBE_COMMIT/CUBE_BUILD_TIME > local git/date fallback.
CUBE_VERSION ?= $(shell git describe --tags --abbrev=0 --match 'v*' 2>/dev/null || echo 0.0.0-dev)
CUBE_COMMIT ?= $(shell git rev-parse HEAD 2>/dev/null || echo unknown)
CUBE_BUILD_TIME ?= $(shell date -u +'%Y-%m-%dT%H:%M:%SZ')

VERSION_PKG=$(PKG)/version
BUILD_FLAGS=-ldflags "-s -w \
  -X '$(VERSION_PKG).Version=$(CUBE_VERSION)' \
  -X '$(VERSION_PKG).Commit=$(CUBE_COMMIT)' \
  -X '$(VERSION_PKG).BuildTime=$(CUBE_BUILD_TIME)'"
APP_VERSION ?= $(CUBE_VERSION)
GIT_COMMIT_SHORT ?= $(shell echo $(CUBE_COMMIT) | cut -c1-7)
PUBLISH_NAME=cubelet-$(APP_VERSION).zip

# use for mark docker image tags
APP_BUILD_VERSION=$(APP_VERSION)-$(GIT_COMMIT_SHORT)

#
CONF_VERSION=1.1.7
DYNAMIC_CONF_DIR=$(BUILD_DIR)/cube-cubelet-conf
DYNAMIC_PUBLISH_NAME=cube-cubelet-conf-$(CONF_VERSION).zip


.PHONY: build deps check-proto-tools fmt lint dep clean
build: $(APPS)
deps:
	$(call msg,Download modules)
	$(Q)go mod download

check-proto-tools:
	@./hack/install-proto-tools.sh
	@$(PROTOC) --version | grep -qx 'libprotoc 28.3' || { echo "error: expected protoc v$(PROTOC_VERSION)"; exit 1; }
	@protoc-gen-go --version | grep -qx 'protoc-gen-go v1.36.11' || { echo "error: expected protoc-gen-go v1.36.11"; exit 1; }
	@protoc-gen-go-grpc --version | grep -qx 'protoc-gen-go-grpc 1.6.1' || { echo "error: expected protoc-gen-go-grpc 1.6.1"; exit 1; }

$(APPS): deps
	@echo "${GOOS}"
	@echo "${CUBE_VERSION}"
	$(call msg,Build app,$@)
	mkdir -p $(BUILD_DIR)
	$(Q)go build -o $(BUILD_DIR)/$@ \
		$(BUILD_FLAGS) \
		cmd/$@/*.go

pack:build
	$(call msg,Build package)
	$(Q)mkdir -p $(PACK_DIR)/bin $(PACK_DIR)/conf $(PACK_DIR)/scripts
	$(Q)cp -rf $(BUILD_DIR)/cubecli $(PACK_DIR)/bin/
	$(Q)cp -rf $(BUILD_DIR)/cubelet $(PACK_DIR)/bin/
	$(Q)cp ./contrib/unsquashfs-dio $(PACK_DIR)/bin/
	$(Q)cp ./contrib/unsquashfs $(PACK_DIR)/bin/
	$(Q)cp ./contrib/nicl $(PACK_DIR)/bin/
	$(Q)cp ./contrib/cubelet-code-deploy.sh $(PACK_DIR)/bin/
	$(Q)cp -rf config/* $(PACK_DIR)/conf/
	$(Q)tar -czf $(PACK_DIR)/conf/benchmark-tool.tar.gz -C $(PACK_DIR)/conf/ benchmark
	$(Q)rm -rf $(PACK_DIR)/conf/benchmark/
	$(Q)cp -rf scripts/* $(PACK_DIR)/scripts/
	$(Q)mv -f $(PACK_DIR)/conf/plugin.conf $(PACK_DIR)/
	$(Q)rm -f $(BUILD_DIR)/$(PUBLISH_NAME)

	$(Q)cd ./build && zip -q -r  $(BUILD_DIR)/$(PUBLISH_NAME) ./cube-let
	$(Q)rm -rf $(PACK_DIR)

packconf:
	$(Q)mkdir -p $(DYNAMIC_CONF_DIR)
	$(Q)cp -rf dynamicconf/* $(DYNAMIC_CONF_DIR)/
	$(Q)echo $(CONF_VERSION)-$(GIT_COMMIT_SHORT)-$(CUBE_BUILD_TIME) > $(DYNAMIC_CONF_DIR)/version
	$(Q)cd ./build && zip -q -r  $(BUILD_DIR)/$(DYNAMIC_PUBLISH_NAME) ./cube-cubelet-conf
	$(Q)rm -rf $(PACK_DIR)

proto: check-proto-tools
	$(call msg,Generate proto)
	@( for pkg in ${PROTO}; do \
		echo $$pkg ;\
		$(PROTOC) $(PROTOC_INCLUDE_FLAGS) $(PROTOC_GO_FLAGS) \
		api/$$pkg/v1/*.proto ;\
	done)
	@if command -v protoc-gen-doc >/dev/null 2>&1; then \
		printf '  %-8s %s\n' "Generate" "proto doc"; \
		$(PROTOC) $(PROTOC_INCLUDE_FLAGS) --doc_out=./doc/ --doc_opt=markdown,cubelet-api.md $(PROTO_DOC_FILES); \
	else \
		printf '  %-8s %s\n' "Skip" "proto doc (missing protoc-gen-doc)"; \
	fi

.PHONY: test
test:
	$(call msg,Run unit tests)
	$(Q)go clean -testcache
	$(Q)mkdir -p coverage
	@( for pkg in ${COVERAGE_PACKAGES}; do \
		CI=true go test ${TEST_FLAGS} \
			-coverprofile=coverage/unit-test-`echo $$pkg | tr "/" "_"`.cov \
			$$pkg || exit 1 ;\
	done )
	# todo: add integration test

.PHONY: coverage
coverage:
	$(Q)echo 'mode: set' > ./coverage/cubelet.cov
	$(Q)tail -q -n +2 ./coverage/*.cov >> ./coverage/cubelet.cov
	$(Q)go tool cover -func=./coverage/cubelet.cov
	$(Q)go tool cover -html=./coverage/cubelet.cov -o ./coverage/cover.html

view:
	$(call msg,Show coverage report)
	$(Q)go tool cover -html=$(COVERAGE_PROFILE)

fmt:
	$(call msg,Format code)
	$(Q)go fmt ./...

lint:
	$(call msg,Run linters)
	$(Q)go fmt ./...
	$(Q)golangci-lint run

dep:
	$(call msg,Update dependencies)
	$(Q)go mod tidy
	$(Q)go mod download

clean:
	$(call msg,Clean)
	$(Q)rm -rf $(BUILD_DIR)/* $(COVERAGE_PROFILE)
	$(Q)rm -rf coverage/*

.PHONY: unittest
unittest:
	@echo "unittest"
