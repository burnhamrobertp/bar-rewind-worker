//! Keeping out of the owner's way and the disk in check: no new job while they play BAR or the machine is
//! short of memory or disk, and engines no parse has used for a month deleted. Games and maps stay: games
//! share BAR's deduplicated package pool, and maps are small.

const std = @import("std");
const builtin = @import("builtin");
const system = @import("system.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const windows = builtin.os.tag == .windows;

const min_free_memory_mb = 4096;
const min_free_disk_mb = 10 * 1024;
const engine_days = 30;
const used_marker = ".bar-rewind-used";

pub const Busy = enum {
    none,
    playing,
    low_memory,
    low_disk,

    pub fn reason(b: Busy) []const u8 {
        return switch (b) {
            .none => "",
            .playing => "BAR is running here",
            .low_memory => std.fmt.comptimePrint("less than {d} GB of memory is free", .{min_free_memory_mb / 1024}),
            .low_disk => std.fmt.comptimePrint("less than {d} GB of disk is free", .{min_free_disk_mb / 1024}),
        };
    }
};

pub fn busy(arena: Allocator, io: Io, bar: []const u8) Busy {
    if (barRunning(arena, io)) return .playing;
    const memory = system.memory(io);
    if (memory.total_mb > 0 and memory.free_mb < min_free_memory_mb) return .low_memory;
    const disk = system.diskFreeMb(arena, bar);
    if (disk > 0 and disk < min_free_disk_mb) return .low_disk;

    return .none;
}

/// BAR as people play it runs spring; a parse runs spring-headless
fn barRunning(arena: Allocator, io: Io) bool {
    if (windows) {
        const snapshot = win32.CreateToolhelp32Snapshot(snap_process, 0);
        if (snapshot == std.os.windows.INVALID_HANDLE_VALUE) return false;
        defer std.os.windows.CloseHandle(snapshot);
        var entry: ProcessEntry = .{};
        var more = win32.Process32FirstW(snapshot, &entry).toBool();
        while (more) : (more = win32.Process32NextW(snapshot, &entry).toBool()) {
            const name = std.mem.sliceTo(&entry.exe_file, 0);
            const utf8 = std.unicode.wtf16LeToWtf8Alloc(arena, name) catch continue;
            if (std.ascii.eqlIgnoreCase(utf8, "spring.exe")) return true;
        }

        return false;
    }
    var proc = Io.Dir.cwd().openDir(io, "/proc", .{ .iterate = true }) catch return false;
    defer proc.close(io);
    var it = proc.iterate();
    var buffer: [64]u8 = undefined;
    while (it.next(io) catch return false) |entry| {
        _ = std.fmt.parseInt(u32, entry.name, 10) catch continue;
        var path: [48]u8 = undefined;
        const comm = proc.readFile(io, std.fmt.bufPrint(&path, "{s}/comm", .{entry.name}) catch continue, &buffer) catch continue;
        if (std.mem.eql(u8, std.mem.trim(u8, comm, "\n"), "spring")) return true;
    }

    return false;
}

/// The engine folders in a BAR data folder: the launcher's engine/recoil_<version>, and pr-downloader's
/// engine/<platform>/<version>
fn engineDirs(arena: Allocator, io: Io, bar: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    const engines = try std.fs.path.join(arena, &.{ bar, "engine" });
    for ([_]?[]const u8{ null, if (windows) "windows64" else "linux64" }) |sub| {
        const parent = if (sub) |s| try std.fs.path.join(arena, &.{ engines, s }) else engines;
        var dir = Io.Dir.cwd().openDir(io, parent, .{ .iterate = true }) catch continue;
        defer dir.close(io);
        var it = dir.iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind != .directory or std.mem.endsWith(u8, entry.name, ".part")) continue;
            if (sub == null and !std.mem.startsWith(u8, entry.name, "recoil_")) continue;
            try out.append(arena, try std.fs.path.join(arena, &.{ parent, entry.name }));
        }
    }

    return out.items;
}

fn versionOf(path: []const u8) []const u8 {
    const base = std.fs.path.basename(path);

    return if (std.mem.startsWith(u8, base, "recoil_")) base["recoil_".len..] else base;
}

/// Stamps the engine `version` with when it was used: the time goes in the marker itself, since Zig can't
/// set a file's times on Windows yet
pub fn markUsed(arena: Allocator, io: Io, bar: []const u8, version: []const u8, now_s: i64) void {
    const dirs = engineDirs(arena, io, bar) catch return;
    for (dirs) |d| if (std.mem.eql(u8, versionOf(d), version)) {
        const marker = std.fs.path.join(arena, &.{ d, used_marker }) catch return;
        const stamp = std.fmt.allocPrint(arena, "{d}", .{now_s}) catch return;
        Io.Dir.cwd().writeFile(io, .{ .sub_path = marker, .data = stamp }) catch {};
    };
}

/// When a parse last used the engine in `dir`, in seconds; before any did, when it was installed
fn lastUsed(arena: Allocator, io: Io, dir: []const u8) i64 {
    const marker = std.fs.path.join(arena, &.{ dir, used_marker }) catch return 0;
    var buffer: [32]u8 = undefined;
    if (Io.Dir.cwd().readFile(io, marker, &buffer)) |text| {
        if (std.fmt.parseInt(i64, std.mem.trim(u8, text, " \r\n"), 10)) |s| return s else |_| {}
    } else |_| {}
    const stat = Io.Dir.cwd().statFile(io, dir, .{}) catch return 0;

    return @intCast(@divFloor(stat.mtime.nanoseconds, std.time.ns_per_s));
}

/// Deletes engines unused for engine_days, except the newest recoil_ one: the parser runs pr-downloader
/// from those
pub fn pruneEngines(arena: Allocator, io: Io, bar: []const u8) void {
    const dirs = engineDirs(arena, io, bar) catch return;
    var newest: ?[]const u8 = null;
    for (dirs) |d| {
        if (!std.mem.startsWith(u8, std.fs.path.basename(d), "recoil_")) continue;
        if (newest == null or std.mem.order(u8, versionOf(d), versionOf(newest.?)) == .gt) newest = d;
    }
    const cutoff = Io.Timestamp.now(io, .real).toSeconds() - engine_days * std.time.s_per_day;
    for (dirs) |d| {
        if ((newest != null and d.ptr == newest.?.ptr) or lastUsed(arena, io, d) >= cutoff) continue;
        std.log.info("deleting engine {s}, unused for {d} days", .{ versionOf(d), engine_days });
        Io.Dir.cwd().deleteTree(io, d) catch |err| std.log.warn("can't delete {s}: {s}", .{ d, @errorName(err) });
    }
}

const snap_process = 0x2;

const ProcessEntry = extern struct {
    size: u32 = @sizeOf(ProcessEntry),
    usage: u32 = 0,
    process_id: u32 = 0,
    default_heap_id: usize = 0,
    module_id: u32 = 0,
    threads: u32 = 0,
    parent_process_id: u32 = 0,
    priority_class_base: i32 = 0,
    flags: u32 = 0,
    exe_file: [260]u16 = @splat(0),
};

const win32 = if (windows) struct {
    extern "kernel32" fn CreateToolhelp32Snapshot(flags: u32, process_id: u32) callconv(.winapi) std.os.windows.HANDLE;
    extern "kernel32" fn Process32FirstW(snapshot: std.os.windows.HANDLE, entry: *ProcessEntry) callconv(.winapi) std.os.windows.BOOL;
    extern "kernel32" fn Process32NextW(snapshot: std.os.windows.HANDLE, entry: *ProcessEntry) callconv(.winapi) std.os.windows.BOOL;
} else struct {};

test "old engines go, the newest and recently used stay" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const bar = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const platform = if (windows) "windows64" else "linux64";
    for ([_][]const u8{ "engine/recoil_2026.01.01", "engine/recoil_2026.07.04", "engine/recoil_2026.09.01", "engine/" ++ platform ++ "/2026.10.01", "engine/recoil_2026.02.02.part" }) |d|
        try tmp.dir.createDirPath(io, d);
    const now = Io.Timestamp.now(io, .real).toSeconds();
    const old = try std.fmt.allocPrint(arena, "{d}", .{now - 31 * std.time.s_per_day});
    for ([_][]const u8{ "engine/recoil_2026.01.01", "engine/recoil_2026.07.04", "engine/recoil_2026.09.01", "engine/" ++ platform ++ "/2026.10.01" }) |d| {
        try tmp.dir.writeFile(io, .{ .sub_path = try std.fmt.allocPrint(arena, "{s}/" ++ used_marker, .{d}), .data = old });
    }
    markUsed(arena, io, bar, "2026.07.04", now);
    pruneEngines(arena, io, bar);

    var left: std.ArrayList([]const u8) = .empty;
    for (try engineDirs(arena, io, bar)) |d| try left.append(arena, versionOf(d));
    std.mem.sort([]const u8, left.items, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.less);
    try std.testing.expectEqual(2, left.items.len);
    try std.testing.expectEqualStrings("2026.07.04", left.items[0]);
    try std.testing.expectEqualStrings("2026.09.01", left.items[1]);
}
