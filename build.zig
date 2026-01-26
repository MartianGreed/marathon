const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Shared library module
    const common_mod = b.createModule(.{
        .root_source_file = b.path("common/src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Orchestrator
    const orchestrator = b.addExecutable(.{
        .name = "marathon-orchestrator",
        .root_module = b.createModule(.{
            .root_source_file = b.path("orchestrator/src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "common", .module = common_mod },
            },
        }),
    });
    b.installArtifact(orchestrator);

    const run_orchestrator = b.addRunArtifact(orchestrator);
    run_orchestrator.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_orchestrator.addArgs(args);
    }
    const run_orchestrator_step = b.step("run-orchestrator", "Run the orchestrator");
    run_orchestrator_step.dependOn(&run_orchestrator.step);

    // Node Operator
    const node_operator = b.addExecutable(.{
        .name = "marathon-node-operator",
        .root_module = b.createModule(.{
            .root_source_file = b.path("node_operator/src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "common", .module = common_mod },
            },
        }),
    });
    b.installArtifact(node_operator);

    const run_node_operator = b.addRunArtifact(node_operator);
    run_node_operator.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_node_operator.addArgs(args);
    }
    const run_node_operator_step = b.step("run-node-operator", "Run the node operator");
    run_node_operator_step.dependOn(&run_node_operator.step);

    // VM Agent (compiled for guest VM)
    const vm_agent = b.addExecutable(.{
        .name = "marathon-vm-agent",
        .root_module = b.createModule(.{
            .root_source_file = b.path("vm_agent/src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "common", .module = common_mod },
            },
        }),
    });
    b.installArtifact(vm_agent);

    // Client CLI
    const client = b.addExecutable(.{
        .name = "marathon",
        .root_module = b.createModule(.{
            .root_source_file = b.path("client/src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "common", .module = common_mod },
            },
        }),
    });
    b.installArtifact(client);

    const run_client = b.addRunArtifact(client);
    run_client.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_client.addArgs(args);
    }
    const run_client_step = b.step("run-client", "Run the CLI client");
    run_client_step.dependOn(&run_client.step);

    // Tests
    const test_step = b.step("test", "Run all tests");

    const common_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("common/src/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_common_tests = b.addRunArtifact(common_tests);
    test_step.dependOn(&run_common_tests.step);

    const orchestrator_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("orchestrator/src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "common", .module = common_mod },
            },
        }),
    });
    const run_orchestrator_tests = b.addRunArtifact(orchestrator_tests);
    test_step.dependOn(&run_orchestrator_tests.step);

    const node_operator_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("node_operator/src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "common", .module = common_mod },
            },
        }),
    });
    const run_node_operator_tests = b.addRunArtifact(node_operator_tests);
    test_step.dependOn(&run_node_operator_tests.step);

    const vm_agent_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("vm_agent/src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "common", .module = common_mod },
            },
        }),
    });
    const run_vm_agent_tests = b.addRunArtifact(vm_agent_tests);
    test_step.dependOn(&run_vm_agent_tests.step);

    const client_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("client/src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "common", .module = common_mod },
            },
        }),
    });
    const run_client_tests = b.addRunArtifact(client_tests);
    test_step.dependOn(&run_client_tests.step);
}
