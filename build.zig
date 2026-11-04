const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{ .default_target = .{ .abi = .gnu } });
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSafe });

    const worker = b.addExecutable(.{
        .name = "bar-rewind-worker",
        .root_module = b.createModule(.{ .root_source_file = b.path("src/main.zig"), .target = target, .optimize = optimize }),
    });
    b.installArtifact(worker);
    const run = b.addRunArtifact(worker);
    run.addPassthruArgs();
    b.step("run", "Run the worker: zig build run -- [--server <url>]").dependOn(&run.step);

    const tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("src/tests.zig"), .target = target }) });
    b.step("test", "Run unit tests").dependOn(&b.addRunArtifact(tests).step);
}
