.PHONY: all build test clean install run-orchestrator run-node-operator run-client snapshot rootfs kernel

ZIG ?= zig
INSTALL_DIR ?= /usr/local/bin
SNAPSHOT_DIR ?= /var/lib/marathon/snapshots
KERNEL_DIR ?= /var/lib/marathon/kernel
ROOTFS_DIR ?= /var/lib/marathon/rootfs

all: build

build:
	$(ZIG) build

build-release:
	$(ZIG) build -Doptimize=ReleaseFast

test:
	$(ZIG) build test

clean:
	rm -rf zig-out zig-cache .zig-cache

install: build-release
	install -d $(INSTALL_DIR)
	install -m 755 zig-out/bin/marathon-orchestrator $(INSTALL_DIR)/
	install -m 755 zig-out/bin/marathon-node-operator $(INSTALL_DIR)/
	install -m 755 zig-out/bin/marathon-vm-agent $(INSTALL_DIR)/
	install -m 755 zig-out/bin/marathon $(INSTALL_DIR)/

run-orchestrator: build
	./zig-out/bin/marathon-orchestrator

run-node-operator: build
	./zig-out/bin/marathon-node-operator

run-client: build
	./zig-out/bin/marathon $(ARGS)

kernel:
	@echo "Downloading kernel..."
	mkdir -p $(KERNEL_DIR)
	cd snapshot/kernel && bash download_kernel.sh 5.10.217 $(KERNEL_DIR)

rootfs: build
	@echo "Creating rootfs..."
	mkdir -p $(ROOTFS_DIR)
	cd snapshot && bash create_rootfs.sh rootfs 4G $(ROOTFS_DIR)/rootfs.ext4

snapshot: kernel rootfs
	@echo "Creating VM snapshot..."
	mkdir -p $(SNAPSHOT_DIR)
	cd snapshot && bash create_snapshot.sh /tmp/marathon-snapshot.sock $(SNAPSHOT_DIR)/base $(KERNEL_DIR)/vmlinux $(ROOTFS_DIR)/rootfs.ext4

docker-build:
	docker build -t marathon-builder -f deploy/Dockerfile.builder .
	docker run --rm -v $(PWD):/workspace marathon-builder zig build -Doptimize=ReleaseFast

proto-check:
	@echo "Validating proto files..."
	protoc --proto_path=proto --descriptor_set_out=/dev/null proto/marathon/v1/*.proto

lint:
	@echo "Running lints..."
	$(ZIG) fmt --check .

format:
	$(ZIG) fmt .

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
	@echo "  rootfs          Create the VM rootfs"
	@echo "  snapshot        Create a VM snapshot"
	@echo "  proto-check     Validate proto files"
	@echo "  lint            Check code formatting"
	@echo "  format          Format code"
	@echo ""
	@echo "Environment:"
	@echo "  ZIG             Zig compiler (default: zig)"
	@echo "  INSTALL_DIR     Installation directory (default: /usr/local/bin)"
	@echo "  SNAPSHOT_DIR    Snapshot directory (default: /var/lib/marathon/snapshots)"
	@echo "  KERNEL_DIR      Kernel directory (default: /var/lib/marathon/kernel)"
	@echo "  ROOTFS_DIR      Rootfs directory (default: /var/lib/marathon/rootfs)"
