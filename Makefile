.PHONY: all build build-release test lint format clean install run-orchestrator run-node-operator run-client snapshot rootfs vm-agent-musl kernel docker-build infra-up infra-down coverage coverage-node-operator coverage-html proto-check help

CARGO ?= cargo
INSTALL_DIR ?= /usr/local/bin
SNAPSHOT_DIR ?= /var/lib/marathon/snapshots
KERNEL_DIR ?= /var/lib/marathon/kernel
ROOTFS_DIR ?= /var/lib/marathon/rootfs

all: build

build:
	$(CARGO) build --workspace

build-release:
	$(CARGO) build --workspace --release

test:
	$(CARGO) test --workspace

clean:
	$(CARGO) clean

install: build-release
	install -d $(INSTALL_DIR)
	install -m 755 target/release/marathon-orchestrator $(INSTALL_DIR)/
	install -m 755 target/release/marathon-node-operator $(INSTALL_DIR)/
	install -m 755 target/release/marathon-vm-agent $(INSTALL_DIR)/
	install -m 755 target/release/marathon $(INSTALL_DIR)/

run-orchestrator: build
	./target/debug/marathon-orchestrator

run-node-operator: build
	./target/debug/marathon-node-operator

run-client: build
	./target/debug/marathon $(ARGS)

kernel:
	@echo "Downloading kernel..."
	mkdir -p $(KERNEL_DIR)
	cd snapshot/kernel && bash download_kernel.sh 5.10.217 $(KERNEL_DIR)

vm-agent-musl:
	rustup target add x86_64-unknown-linux-musl
	$(CARGO) build --release --locked -p marathon-vm-agent --target x86_64-unknown-linux-musl

rootfs: vm-agent-musl
	@echo "Creating rootfs..."
	mkdir -p $(ROOTFS_DIR)
	cd snapshot && bash create_rootfs.sh rootfs 4G $(ROOTFS_DIR)/rootfs.ext4

snapshot: kernel rootfs
	@echo "Creating VM snapshot..."
	mkdir -p $(SNAPSHOT_DIR)
	cd snapshot && bash create_snapshot.sh /tmp/marathon-snapshot.sock $(SNAPSHOT_DIR)/base $(KERNEL_DIR)/vmlinux $(ROOTFS_DIR)/rootfs.ext4

docker-build:
	docker build --load -t marathon-builder -f deploy/Dockerfile.builder .
	docker run --rm -e CARGO_TARGET_DIR=/tmp/marathon-target -v $(PWD):/workspace -w /workspace marathon-builder sh -ec ' \
		cargo build --workspace --release --locked; \
		mkdir -p target/docker/release; \
		for binary in marathon-orchestrator marathon-node-operator marathon-vm-agent marathon; do \
			cp "$$CARGO_TARGET_DIR/release/$$binary" target/docker/release/; \
		done' 

infra-up:
	docker compose up -d
	@echo "Waiting for services..."
	@sleep 3
	@docker compose ps

infra-down:
	docker compose down

proto-check:
	@echo "Validating proto files..."
	protoc --proto_path=proto --descriptor_set_out=/dev/null proto/marathon/v1/*.proto

lint:
	@echo "Running lints..."
	$(CARGO) fmt --all --check
	$(CARGO) clippy --workspace --all-targets -- -D warnings

format:
	$(CARGO) fmt --all

COVERAGE_DIR ?= coverage

coverage-node-operator:
	@echo "Running node_operator tests with coverage..."
	@mkdir -p $(COVERAGE_DIR)/node_operator
	@CARGO="$(CARGO)" ./scripts/coverage.sh node_operator $(COVERAGE_DIR)/node_operator

coverage:
	@echo "Running all tests with coverage..."
	@mkdir -p $(COVERAGE_DIR)
	@CARGO="$(CARGO)" ./scripts/coverage.sh all $(COVERAGE_DIR)

coverage-html:
	@report="$(COVERAGE_DIR)/index.html"; \
	if [ ! -f "$$report" ]; then report="$(COVERAGE_DIR)/node_operator/index.html"; fi; \
	if [ -f "$$report" ]; then \
		open "$$report" 2>/dev/null || xdg-open "$$report" 2>/dev/null || echo "Open $$report in your browser"; \
	else \
		echo "No coverage report found. Run 'make coverage' first."; \
	fi

help:
	@echo "Marathon Build System"
	@echo ""
	@echo "Targets:"
	@echo "  build           Build all binaries (debug)"
	@echo "  build-release   Build all binaries (release)"
	@echo "  test            Run all tests"
	@echo "  clean           Remove build artifacts"
	@echo "  install         Install binaries to INSTALL_DIR"
	@echo "  run-orchestrator  Run the orchestrator"
	@echo "  run-node-operator Run the node operator"
	@echo "  run-client      Run the CLI client (use ARGS=...)"
	@echo "  kernel          Download the VM kernel"
	@echo "  vm-agent-musl   Build the static Linux VM agent"
	@echo "  docker-build    Build releases in the Rust builder container"
	@echo "  rootfs          Create the VM rootfs"
	@echo "  snapshot        Create a VM snapshot"
	@echo "  proto-check     Validate proto files"
	@echo "  lint            Check formatting and Clippy"
	@echo "  format          Format code"
	@echo "  infra-up        Start Docker infrastructure (postgres, redis, etcd)"
	@echo "  infra-down      Stop Docker infrastructure"
	@echo "  coverage-node-operator  Run node_operator tests with coverage"
	@echo "  coverage        Run all tests with coverage"
	@echo "  coverage-html   Open coverage report in browser"
	@echo ""
	@echo "Environment:"
	@echo "  CARGO           Cargo command (default: cargo)"
	@echo "  INSTALL_DIR     Installation directory (default: /usr/local/bin)"
	@echo "  SNAPSHOT_DIR    Snapshot directory (default: /var/lib/marathon/snapshots)"
	@echo "  KERNEL_DIR      Kernel directory (default: /var/lib/marathon/kernel)"
	@echo "  ROOTFS_DIR      Rootfs directory (default: /var/lib/marathon/rootfs)"
	@echo "  COVERAGE_DIR    Coverage output directory (default: coverage)"
