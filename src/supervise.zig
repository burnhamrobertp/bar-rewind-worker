//! --background: the worker as the scheduled task starts it. No console window; it runs the worker itself
//! as a child with its output in worker.log (the run before in worker.log.1), starting it again at once
//! after an update (restart_code) and after a growing pause when it stops any other way.

const std = @import("std");
const builtin = @import("builtin");
const system = @import("system.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;

const first_pause = 30;
const longest_pause = 10 * 60;
const healthy_seconds = 10 * 60;

fn rotate(arena: Allocator, io: Io, log: []const u8) void {
    const previous = std.fmt.allocPrint(arena, "{s}.1", .{log}) catch return;
    Io.Dir.cwd().deleteFile(io, previous) catch {};
    Io.Dir.cwd().rename(log, Io.Dir.cwd(), previous, io) catch {};
}

/// How long to wait before starting the worker again after it stopped with `code` having run `seconds`
pub fn pauseAfter(code: ?u8, seconds: i64, previous: u64, restart_code: u8) u64 {
    if (code == restart_code) return 0;
    if (seconds >= healthy_seconds) return first_pause;

    return if (previous == 0) first_pause else @min(previous * 2, longest_pause);
}

pub fn run(arena: Allocator, io: Io, home: []const u8, args: []const []const u8, restart_code: u8) !noreturn {
    if (builtin.os.tag == .windows) _ = win32.FreeConsole();
    const exe = try std.process.executablePathAlloc(io, arena);
    const log = try std.fs.path.join(arena, &.{ home, "worker.log" });
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(arena, exe);
    for (args) |a| if (!std.mem.eql(u8, a, "--background")) try argv.append(arena, a);
    try argv.append(arena, "--unattended");

    var pause: u64 = 0;
    while (true) {
        rotate(arena, io, log);
        const out = try Io.Dir.cwd().createFile(io, log, .{});
        const started = Io.Timestamp.now(io, .awake);
        // an update puts the new worker at this same path
        const code: ?u8 = if (std.process.spawn(io, .{ .argv = argv.items, .stdin = .ignore, .stdout = .{ .file = out }, .stderr = .{ .file = out }, .create_no_window = true })) |child_const| blk: {
            var child = child_const;
            var tree = system.Tree.watch(&child);
            defer tree.close();
            const term = child.wait(io) catch break :blk null;
            break :blk if (term == .exited) term.exited else null;
        } else |_| null;
        out.close(io);
        pause = pauseAfter(code, started.untilNow(io, .awake).toSeconds(), pause, restart_code);
        try io.sleep(.fromSeconds(@intCast(pause)), .awake);
    }
}

const win32 = if (builtin.os.tag == .windows) struct {
    extern "kernel32" fn FreeConsole() callconv(.winapi) std.os.windows.BOOL;
} else struct {};

test "an update restarts at once, a crash loop backs off, a long run starts over" {
    try std.testing.expectEqual(0, pauseAfter(75, 5, 600, 75));
    try std.testing.expectEqual(first_pause, pauseAfter(1, 5, 0, 75));
    try std.testing.expectEqual(first_pause * 2, pauseAfter(1, 5, first_pause, 75));
    try std.testing.expectEqual(longest_pause, pauseAfter(null, 5, longest_pause, 75));
    try std.testing.expectEqual(first_pause, pauseAfter(1, healthy_seconds, longest_pause, 75));
}
