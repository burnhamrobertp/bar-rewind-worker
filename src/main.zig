//! bar-rewind-worker: parses replays for a BAR Rewind server on a moderator's machine.
//!   bar-rewind-worker [--server <url>] [--bake <path>]
//! The first run enrolls: it shows a code and opens the server's site, where the machine's owner approves
//! it. After that it asks the server for work, parses with BAR-Rewind's bake in a BAR data folder of its
//! own (seeded with an engine from the BAR install here), and reports back.

const std = @import("std");
const builtin = @import("builtin");
const api = @import("api.zig");
const job = @import("job.zig");
const state = @import("state.zig");
const system = @import("system.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const windows = builtin.os.tag == .windows;
const exe_suffix = if (windows) ".exe" else "";
const default_server = "https://bar-rewind.robotofham.com";
const version = "0.1.0";

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = std.heap.smp_allocator;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    var server_url: []const u8 = default_server;
    var bake: ?[]const u8 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (i + 1 < args.len and std.mem.eql(u8, args[i], "--server")) {
            i += 1;
            server_url = args[i];
        } else if (i + 1 < args.len and std.mem.eql(u8, args[i], "--bake")) {
            i += 1;
            bake = args[i];
        } else {
            std.debug.print("usage: bar-rewind-worker [--server <url>] [--bake <path>]\n", .{});
            std.process.exit(2);
        }
    }

    const home = try homeDir(arena, init.environ_map);
    try Io.Dir.cwd().createDirPath(io, home);
    const paths: job.Paths = .{
        .bake = bake orelse try std.fs.path.join(arena, &.{ try std.process.executableDirPathAlloc(io, arena), "bake" ++ exe_suffix }),
        .bar = try std.fs.path.join(arena, &.{ home, "bar" }),
        .work = try std.fs.path.join(arena, &.{ home, "work" }),
    };
    const state_path = try std.fs.path.join(arena, &.{ home, "worker.json" });
    system.lowerPriority();
    try seedEngine(arena, io, init.environ_map, paths.bar);

    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    var server: api.Api = .{ .client = &client, .base = server_url };
    while (true) {
        var loop_arena: std.heap.ArenaAllocator = .init(gpa);
        defer loop_arena.deinit();
        const a = loop_arena.allocator();
        const saved = try state.load(io, a, state_path);
        const me = if (saved) |s| (if (std.mem.eql(u8, s.server, server_url)) s else null) else null;
        if (me == null) {
            const enrolled = enroll(a, io, &server, init.environ_map) catch |err| {
                std.log.err("enrolling with {s} failed ({s}); trying again in a minute", .{ server_url, @errorName(err) });
                try io.sleep(.fromSeconds(60), .awake);
                continue;
            };
            try state.save(io, a, state_path, enrolled);
            std.log.info("enrolled as worker {s}", .{enrolled.worker_id});
            continue;
        }
        server.token = me.?.token;
        const wait = serve(gpa, io, &server, paths) catch |err| switch (err) {
            error.Revoked => {
                std.log.warn("the server no longer knows this worker: enrolling again", .{});
                state.forget(io, state_path);
                continue;
            },
            else => blk: {
                std.log.warn("talking to the server failed: {s}", .{@errorName(err)});
                break :blk 30;
            },
        };
        try io.sleep(.fromSeconds(@intCast(wait)), .awake);
    }
}

fn homeDir(arena: Allocator, env: *std.process.Environ.Map) ![]const u8 {
    if (windows) return std.fs.path.join(arena, &.{ env.get("LOCALAPPDATA") orelse return error.NoLocalAppData, "bar-rewind-worker" });
    if (env.get("XDG_DATA_HOME")) |xdg| return std.fs.path.join(arena, &.{ xdg, "bar-rewind-worker" });

    return std.fs.path.join(arena, &.{ env.get("HOME") orelse return error.NoHome, ".local", "share", "bar-rewind-worker" });
}

fn hostname(arena: Allocator, env: *std.process.Environ.Map) []const u8 {
    if (windows) return env.get("COMPUTERNAME") orelse "worker";
    var buffer: [std.posix.HOST_NAME_MAX]u8 = undefined;

    return arena.dupe(u8, std.posix.gethostname(&buffer) catch return "worker") catch "worker";
}

fn openBrowser(io: Io, url: []const u8) void {
    const argv: []const []const u8 = if (windows) &.{ "rundll32", "url.dll,FileProtocolHandler", url } else &.{ "xdg-open", url };
    var child = std.process.spawn(io, .{ .argv = argv, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore }) catch return;
    _ = child.wait(io) catch {};
}

fn enroll(arena: Allocator, io: Io, server: *api.Api, env: *std.process.Environ.Map) !state.State {
    server.token = null;
    const memory = system.memory(io);
    const start = try server.post(arena, "/api/worker/enroll", .{ .name = hostname(arena, env), .mem_mb = memory.total_mb, .cpus = system.cpus(), .os = system.os_name });
    if (start.status != 200) return error.EnrollRefused;
    const Start = struct { device_code: []const u8, user_code: []const u8, verify_url: []const u8, interval: u64 = 5, expires_in: u64 = 900 };
    const s = try start.parse(Start, arena);
    std.debug.print(
        \\
        \\  Approve this worker: {s}
        \\  It should show the code {s}. The page opens in your browser now.
        \\
        \\
    , .{ s.verify_url, s.user_code });
    openBrowser(io, s.verify_url);

    var waited: u64 = 0;
    while (waited < s.expires_in) : (waited += s.interval) {
        try io.sleep(.fromSeconds(@intCast(s.interval)), .awake);
        const reply = server.post(arena, "/api/worker/enroll/poll", .{ .device_code = s.device_code }) catch continue;
        switch (reply.status) {
            202 => continue,
            200 => {
                const got = try reply.parse(struct { worker_id: []const u8, token: []const u8 }, arena);

                return .{ .server = server.base, .worker_id = got.worker_id, .token = got.token };
            },
            else => return error.EnrollExpired,
        }
    }

    return error.EnrollExpired;
}

const Heartbeat = struct {
    poll_seconds: u64 = 15,
    paused: bool = false,
    pause_reason: ?[]const u8 = null,
};

/// One round: report in, then take and run a job if one fits. Returns how long to wait before the next.
fn serve(gpa: Allocator, io: Io, server: *api.Api, paths: job.Paths) !u64 {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const memory = system.memory(io);
    const beat = try server.post(arena, "/api/worker/heartbeat", .{
        .mem_mb = memory.total_mb, .mem_free_mb = memory.free_mb, .cpus = system.cpus(), .os = system.os_name, .version = version,
        .parser_version = parserVersion(arena, io, paths.bake), .disk_free_mb = system.diskFreeMb(arena, paths.bar),
    });
    if (beat.status == 401) return error.Revoked;
    if (beat.status != 200) return error.Unexpected;
    const settings = try beat.parse(Heartbeat, arena);
    if (settings.paused) return settings.poll_seconds;

    const claim = try server.post(arena, "/api/worker/claim", .{});
    if (claim.status == 401) return error.Revoked;
    if (claim.status == 204) return settings.poll_seconds;
    if (claim.status != 200) return error.Unexpected;
    const work = try claim.parse(job.Claim, arena);
    std.log.info("parsing {s}", .{work.job.id});
    job.run(gpa, io, server, paths, work) catch |err| std.log.warn("job {s}: {s}", .{ work.job.id, @errorName(err) });

    return 0;
}

/// What `bake version` says: the parser's .curves format, until releases pin it by name
fn parserVersion(arena: Allocator, io: Io, bake: []const u8) []const u8 {
    const result = std.process.run(arena, io, .{ .argv = &.{ bake, "version" }, .create_no_window = true }) catch return "";
    const text = std.mem.trim(u8, if (result.stderr.len > 0) result.stderr else result.stdout, " \r\n");

    return text[if (std.mem.lastIndexOfScalar(u8, text, ' ')) |at| at + 1 else 0..];
}

/// The parse folder needs one engine for BAR's pr-downloader to fetch the rest: the newest from the BAR
/// install on this machine
fn seedEngine(arena: Allocator, io: Io, env: *std.process.Environ.Map, bar: []const u8) !void {
    const engines = try std.fs.path.join(arena, &.{ bar, "engine" });
    if (hasEngine(io, engines)) return;
    const home = env.get(if (windows) "USERPROFILE" else "HOME") orelse "";
    const candidates: []const []const u8 = if (windows) &.{
        try std.fs.path.join(arena, &.{ env.get("LOCALAPPDATA") orelse home, "Programs", "Beyond-All-Reason", "data" }),
        "C:\\Program Files\\Beyond-All-Reason\\data",
        try std.fs.path.join(arena, &.{ home, "Documents", "Beyond All Reason" }),
    } else &.{
        try std.fs.path.join(arena, &.{ home, ".var", "app", "info.beyondallreason.bar", "data" }),
        try std.fs.path.join(arena, &.{ home, ".local", "state", "Beyond All Reason" }),
        try std.fs.path.join(arena, &.{ home, "Documents", "Beyond All Reason" }),
    };
    for (candidates) |data| {
        const from = try std.fs.path.join(arena, &.{ data, "engine" });
        const newest = newestEngine(arena, io, from) orelse continue;
        std.log.info("copying engine {s} from {s}", .{ newest, from });
        try copyTree(arena, io, try std.fs.path.join(arena, &.{ from, newest }), try std.fs.path.join(arena, &.{ engines, newest }));

        return;
    }

    return error.NoBarInstall;
}

fn hasEngine(io: Io, engines: []const u8) bool {
    var dir = Io.Dir.cwd().openDir(io, engines, .{ .iterate = true }) catch return false;
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch return false) |entry| if (std.mem.startsWith(u8, entry.name, "recoil_") and !std.mem.endsWith(u8, entry.name, ".part")) return true;

    return false;
}

fn newestEngine(arena: Allocator, io: Io, engines: []const u8) ?[]const u8 {
    var dir = Io.Dir.cwd().openDir(io, engines, .{ .iterate = true }) catch return null;
    defer dir.close(io);
    var newest: ?[]const u8 = null;
    var it = dir.iterate();
    while (it.next(io) catch return newest) |entry| {
        if (entry.kind != .directory or !std.mem.startsWith(u8, entry.name, "recoil_")) continue;
        if (newest == null or std.mem.order(u8, entry.name, newest.?) == .gt) newest = arena.dupe(u8, entry.name) catch return newest;
    }

    return newest;
}

fn copyTree(arena: Allocator, io: Io, from: []const u8, to: []const u8) !void {
    var src = try Io.Dir.cwd().openDir(io, from, .{ .iterate = true });
    defer src.close(io);
    const part = try std.fmt.allocPrint(arena, "{s}.part", .{to});
    Io.Dir.cwd().deleteTree(io, part) catch {};
    var dst = try Io.Dir.cwd().createDirPathOpen(io, part, .{});
    defer dst.close(io);
    var walker = try src.walk(arena);
    defer walker.deinit();
    while (try walker.next(io)) |entry| switch (entry.kind) {
        .directory => try dst.createDirPath(io, entry.path),
        .file => try src.copyFile(entry.path, dst, entry.path, io, .{}),
        else => {},
    };
    try Io.Dir.cwd().rename(part, Io.Dir.cwd(), to, io);
}
