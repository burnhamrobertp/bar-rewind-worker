const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{ .default_target = .{ .abi = .gnu } });
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSafe });

    const options = b.addOptions();
    options.addOption([]const u8, "version", b.option([]const u8, "version", "the release this build is (default 0.0.0-dev)") orelse "0.0.0-dev");
    const worker = b.addExecutable(.{
        .name = "bar-rewind-worker",
        .root_module = b.createModule(.{ .root_source_file = b.path("src/main.zig"), .target = target, .optimize = optimize }),
    });
    worker.root_module.addOptions("options", options);
    b.installArtifact(worker);
    const run = b.addRunArtifact(worker);
    run.addPassthruArgs();
    b.step("run", "Run the worker: zig build run -- [--server <url>]").dependOn(&run.step);

    // baseline x86_64 so they run on any CPU
    const dist = b.step("dist", "Build zig-out/dist/: the worker for Windows and Linux");
    for ([_][2][]const u8{ .{ "x86_64-windows-gnu", "bar-rewind-worker.exe" }, .{ "x86_64-linux-musl", "bar-rewind-worker-linux" } }) |p| {
        const exe = b.addExecutable(.{
            .name = "bar-rewind-worker",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main.zig"),
                .target = b.resolveTargetQuery(std.Target.Query.parse(.{ .arch_os_abi = p[0], .cpu_features = "baseline" }) catch unreachable),
                .optimize = .ReleaseSafe,
                .strip = true,
            }),
        });
        exe.root_module.addOptions("options", options);
        dist.dependOn(&b.addInstallArtifact(exe, .{ .dest_dir = .{ .override = .{ .custom = "dist" } }, .dest_sub_path = p[1], .pdb_dir = .disabled }).step);
    }

    const tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("src/tests.zig"), .target = target }) });
    b.step("test", "Run unit tests").dependOn(&b.addRunArtifact(tests).step);
}
