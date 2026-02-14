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

    // Plugin system module
    const plugin_mod = b.createModule(.{
        .root_source_file = b.path("src/plugins/core/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "common", .module = common_mod },
        },
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

    // Client CLI (with plugin support)
    const client = b.addExecutable(.{
        .name = "marathon",
        .root_module = b.createModule(.{
            .root_source_file = b.path("client/src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "common", .module = common_mod },
                .{ .name = "plugins", .module = plugin_mod },
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

    // Plugin examples
    const hello_world_plugin = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/plugins/examples/hello-world/plugin.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    
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

    // Plugin system tests
    const plugin_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/plugins/core/root.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "common", .module = common_mod },
            },
        }),
    });
    const run_plugin_tests = b.addRunArtifact(plugin_tests);
    test_step.dependOn(&run_plugin_tests.step);

    // Plugin system comprehensive tests
    const plugin_system_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/plugins/tests/plugin_system_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_plugin_system_tests = b.addRunArtifact(plugin_system_tests);
    test_step.dependOn(&run_plugin_system_tests.step);

    // Hello world plugin tests
    const run_hello_world_tests = b.addRunArtifact(hello_world_plugin);
    test_step.dependOn(&run_hello_world_tests.step);

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
                .{ .name = "plugins", .module = plugin_mod },
            },
        }),
    });
    const run_client_tests = b.addRunArtifact(client_tests);
    test_step.dependOn(&run_client_tests.step);

    // Plugin-specific test commands
    const plugin_test_step = b.step("test-plugins", "Run plugin system tests only");
    plugin_test_step.dependOn(&run_plugin_tests.step);
    plugin_test_step.dependOn(&run_plugin_system_tests.step);
    plugin_test_step.dependOn(&run_hello_world_tests.step);

    // Plugin CLI test command
    const plugin_cli_step = b.step("plugin-demo", "Run plugin CLI demo");
    const plugin_demo = b.addRunArtifact(client);
    plugin_demo.addArgs(&.{ "plugin", "list" });
    plugin_demo.step.dependOn(b.getInstallStep());
    plugin_cli_step.dependOn(&plugin_demo.step);
}