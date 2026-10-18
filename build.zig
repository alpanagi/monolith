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

    const javascript_plugin = b.createModule(.{
        .root_source_file = b.path("plugins/javascript/generator.zig"),
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
                .{ .name = "javascript", .module = javascript_plugin },
                .{ .name = "c", .module = c_plugin },
            },
        }),
    });
    b.installArtifact(exe);

    b.installDirectory(.{
        .source_dir = b.path("std"),
        .install_dir = .bin,
        .install_subdir = "std",
    });

    for ([_][]const u8{ "javascript", "c" }) |plugin| {
        b.installDirectory(.{
            .source_dir = b.path(b.fmt("plugins/{s}/runtime", .{plugin})),
            .install_dir = .bin,
            .install_subdir = b.fmt("plugins/{s}/runtime", .{plugin}),
        });
    }

    const test_step = b.step("test", "Run tests");
    for ([_]*std.Build.Module{ core, monolith }) |module| {
        const tests = b.addTest(.{ .root_module = module });
        test_step.dependOn(&b.addRunArtifact(tests).step);
    }

    for ([_][]const u8{ "javascript", "c" }) |plugin| {
        const module = b.createModule(.{
            .root_source_file = b.path(b.fmt("plugins/{s}/generator.zig", .{plugin})),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "core", .module = core },
                .{ .name = "monolith", .module = monolith },
            },
        });
        const tests = b.addTest(.{ .root_module = module });
        test_step.dependOn(&b.addRunArtifact(tests).step);
    }
}
