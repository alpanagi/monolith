const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const core = b.createModule(.{
        .root_source_file = b.path("src/core/core.zig"),
        .target = target,
        .optimize = optimize,
    });

    const monolith = b.createModule(.{
        .root_source_file = b.path("src/monolith/monolith.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "core", .module = core }},
    });

    const c_plugin = b.createModule(.{
        .root_source_file = b.path("plugins/c/generator.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "core", .module = core }},
    });

    const exe = b.addExecutable(.{
        .name = "monolith",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "core", .module = core },
                .{ .name = "monolith", .module = monolith },
                .{ .name = "c", .module = c_plugin },
            },
        }),
    });
    b.installArtifact(exe);

    b.installDirectory(.{
        .source_dir = b.path("library/mn"),
        .install_dir = .bin,
        .install_subdir = "mn",
    });

    b.getInstallStep().dependOn(&b.addInstallFileWithDir(b.path("library/mn.mn"), .bin, "mn.mn").step);

    b.installDirectory(.{
        .source_dir = b.path("plugins/c/runtime"),
        .install_dir = .bin,
        .install_subdir = "plugins/c/runtime",
    });

    const test_step = b.step("test", "Run tests");
    const input_marker = addInputMarker(b);
    for ([_]*std.Build.Module{ core, monolith }) |module| {
        const tests = b.addTest(.{ .root_module = module });
        addTestRun(b, test_step, tests, input_marker);
    }

    const c_plugin_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("plugins/c/generator.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "core", .module = core },
                .{ .name = "monolith", .module = monolith },
            },
        }),
    });
    addTestRun(b, test_step, c_plugin_tests, input_marker);
}

fn addInputMarker(b: *std.Build) std.Build.LazyPath {
    const inputs = b.addWriteFiles();
    _ = inputs.addCopyDirectory(b.path("library"), "library", .{});
    _ = inputs.addCopyDirectory(b.path("plugins/c"), "plugins/c", .{});
    return inputs.add("marker", "");
}

fn addTestRun(
    b: *std.Build,
    test_step: *std.Build.Step,
    tests: *std.Build.Step.Compile,
    input_marker: std.Build.LazyPath,
) void {
    const run = b.addRunArtifact(tests);
    run.addFileInput(input_marker);
    test_step.dependOn(&run.step);
}
