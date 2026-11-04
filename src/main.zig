//! bar-rewind-worker: parses replays for a BAR Rewind server on a moderator's machine.
//!   bar-rewind-worker install [--server <url>]   enroll if need be, then run unattended from now on
//!   bar-rewind-worker uninstall                  stop running unattended
//!   bar-rewind-worker [--server <url>] [--bake <path>] [--background]
//! The supervisor started by --background runs the worker with --unattended: one that isn't enrolled stops,
//! since nobody is there to approve it.
//! The first run enrolls: it shows a code and opens the server's site, where the machine's owner approves
//! it. After that it asks the server for work, parses with BAR-Rewind's bake in a BAR data folder of its
//! own (seeded with an engine from the BAR install here), and reports back. It keeps the parser and itself
//! at the releases the server pins; after replacing itself it exits with restart_code, for whatever runs it
//! to start it again.

const std = @import("std");
const builtin = @import("builtin");
const api = @import("api.zig");
const housekeeping = @import("housekeeping.zig");
const install = @import("install.zig");
const job = @import("job.zig");
const state = @import("state.zig");
const supervise = @import("supervise.zig");
const system = @import("system.zig");
const updates = @import("updates.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const windows = builtin.os.tag == .windows;
const exe_suffix = if (windows) ".exe" else "";
const default_server = "https://bar-rewind.robotofham.com";
const version = @import("options").version;
const restart_code = 75;
const parser_asset = if (windows) "bake.exe" else "bake-linux";
const worker_asset = if (windows) "bar-rewind-worker.exe" else "bar-rewind-worker-linux";
const release_key_hex = @embedFile("release-key.pub");

/// The key releases are signed with, or null in a build without one: then nothing updates
fn releaseKey() ?std.crypto.sign.Ed25519.PublicKey {
    const bytes = updates.parseHex(32, release_key_hex) catch return null;

    return std.crypto.sign.Ed25519.PublicKey.fromBytes(bytes) catch null;
}

/// What the worker runs: --bake, else the parser release the server pinned, else a bake beside the worker
const Runtime = struct {
    home: []const u8,
    exe: []const u8,
    bake_override: ?[]const u8,
    fallback_bake: []const u8,
    parser_version: []const u8 = "",
    parser_path: ?[]const u8 = null,
    on_trial: bool = false,
    busy: housekeeping.Busy = .none,

    fn pendingPath(rt: Runtime, arena: Allocator) ![]const u8 {
        return std.fs.path.join(arena, &.{ rt.home, "update.json" });
    }

    fn badPath(rt: Runtime, arena: Allocator) ![]const u8 {
        return std.fs.path.join(arena, &.{ rt.home, "bad-worker-version" });
    }
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = std.heap.smp_allocator;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    const command: enum { serve, install, uninstall } = if (args.len > 1 and std.mem.eql(u8, args[1], "install"))
        .install
    else if (args.len > 1 and std.mem.eql(u8, args[1], "uninstall")) .uninstall else .serve;
    var server_url: []const u8 = default_server;
    var bake: ?[]const u8 = null;
    var background = false;
    var unattended = false;
    var i: usize = if (command == .serve) 1 else 2;
    while (i < args.len) : (i += 1) {
        if (i + 1 < args.len and std.mem.eql(u8, args[i], "--server")) {
            i += 1;
            server_url = args[i];
        } else if (i + 1 < args.len and command == .serve and std.mem.eql(u8, args[i], "--bake")) {
            i += 1;
            bake = args[i];
        } else if (command == .serve and std.mem.eql(u8, args[i], "--background")) {
            background = true;
        } else if (command == .serve and std.mem.eql(u8, args[i], "--unattended")) {
            unattended = true;
        } else {
            std.debug.print("usage: bar-rewind-worker install [--server <url>] | uninstall | [--server <url>] [--bake <path>] [--background]\n", .{});
            std.process.exit(2);
        }
    }

    const home = try homeDir(arena, init.environ_map);
    try Io.Dir.cwd().createDirPath(io, home);
    const state_path = try std.fs.path.join(arena, &.{ home, "worker.json" });
    switch (command) {
        .uninstall => {
            try install.uninstall(arena, io, init.environ_map, install.task_name);
            std.debug.print("The worker no longer starts on its own. Its files are in {s}\n", .{home});

            return;
        },
        .install => {
            var client: std.http.Client = .{ .allocator = gpa, .io = io };
            defer client.deinit();
            var server: api.Api = .{ .client = &client, .base = server_url };
            const saved = try state.load(io, arena, state_path);
            if (saved == null or !std.mem.eql(u8, saved.?.server, server_url)) try state.save(io, arena, state_path, try enroll(arena, io, &server, init.environ_map));
            const exe = try install.install(arena, io, init.environ_map, home, &.{ "--background", "--server", server_url }, install.task_name);
            std.debug.print("The worker runs on its own now, and starts again at every sign-in: {s}\nIts log: {s}\n", .{
                exe, try std.fs.path.join(arena, &.{ home, "worker.log" }),
            });

            return;
        },
        .serve => {},
    }
    if (background) try supervise.run(arena, io, home, args[1..], restart_code);

    // one worker per machine: a second would parse in the same folders
    const lock_path = try std.fs.path.join(arena, &.{ home, "worker.lock" });
    const lock = Io.Dir.cwd().createFile(io, lock_path, .{ .lock = .exclusive, .lock_nonblocking = true, .truncate = false }) catch |err| switch (err) {
        error.WouldBlock => {
            std.log.err("another worker is already running here", .{});
            std.process.exit(1);
        },
        else => return err,
    };
    defer lock.close(io);
    var rt: Runtime = .{
        .home = home,
        .exe = try std.process.executablePathAlloc(io, arena),
        .bake_override = bake,
        .fallback_bake = try std.fs.path.join(arena, &.{ try std.process.executableDirPathAlloc(io, arena), "bake" ++ exe_suffix }),
    };
    try checkTrial(arena, io, &rt);
    if (releaseKey() == null) std.log.warn("this build has no release key: the parser and the worker won't update", .{});
    const paths: job.Paths = .{
        .bake = "",
        .bar = try std.fs.path.join(arena, &.{ home, "bar" }),
        .work = try std.fs.path.join(arena, &.{ home, "work" }),
    };
    system.lowerPriority();
    try seedEngine(arena, io, init.environ_map, paths.bar);
    housekeeping.pruneEngines(arena, io, paths.bar);

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
            if (unattended) {
                std.log.err("this worker isn't enrolled with {s} (or was removed there): run `bar-rewind-worker install` again", .{server_url});
                std.process.exit(1);
            }
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
        const wait = serve(gpa, io, &server, &rt, paths) catch |err| switch (err) {
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
    releases: struct { parser: ?updates.Release = null, worker: ?updates.Release = null } = .{},
};

/// One round: report in, update to the pinned releases, then take and run a job if one fits. Returns how
/// long to wait before the next.
fn serve(gpa: Allocator, io: Io, server: *api.Api, rt: *Runtime, base: job.Paths) !u64 {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var paths = base;
    paths.bake = rt.bake_override orelse rt.parser_path orelse rt.fallback_bake;
    const memory = system.memory(io);
    const beat = try server.post(arena, "/api/worker/heartbeat", .{
        .mem_mb = memory.total_mb, .mem_free_mb = memory.free_mb, .cpus = system.cpus(), .os = system.os_name, .version = version,
        .parser_version = if (rt.bake_override != null or rt.parser_path == null) parserVersion(arena, io, paths.bake) else rt.parser_version,
        .disk_free_mb = system.diskFreeMb(arena, paths.bar),
    });
    if (beat.status == 401) return error.Revoked;
    if (beat.status != 200) return error.Unexpected;
    if (rt.on_trial) endTrial(arena, io, rt);
    const settings = try beat.parse(Heartbeat, arena);
    if (releaseKey()) |key| {
        if (rt.bake_override == null) if (settings.releases.parser) |pin| if (!std.mem.eql(u8, pin.version, rt.parser_version)) {
            try updateParser(gpa, arena, io, server.client, rt, pin, key);

            return 0;
        };
        // a build of your own stays itself
        if (!std.mem.eql(u8, version, "0.0.0-dev")) if (settings.releases.worker) |pin| {
            if (!std.mem.eql(u8, pin.version, version) and !isBad(arena, io, rt.*, pin.version))
                updateWorker(arena, io, server.client, rt.*, pin, key) catch |err| std.log.warn("can't update to worker {s}: {s}", .{ pin.version, @errorName(err) });
        };
    }
    if (settings.paused) return settings.poll_seconds;
    const busy = housekeeping.busy(arena, io, paths.bar);
    if (busy != rt.busy) {
        if (busy == .none) std.log.info("taking jobs again", .{}) else std.log.info("not taking jobs while {s}", .{busy.reason()});
        rt.busy = busy;
    }
    if (busy != .none) return settings.poll_seconds;

    const claim = try server.post(arena, "/api/worker/claim", .{});
    if (claim.status == 401) return error.Revoked;
    if (claim.status == 204) return settings.poll_seconds;
    if (claim.status != 200) return error.Unexpected;
    const work = try claim.parse(job.Claim, arena);
    std.log.info("parsing {s}", .{work.job.id});
    job.run(gpa, io, server, paths, work) catch |err| std.log.warn("job {s}: {s}", .{ work.job.id, @errorName(err) });
    housekeeping.pruneEngines(arena, io, paths.bar);

    return 0;
}

fn updateParser(gpa: Allocator, arena: Allocator, io: Io, client: *std.http.Client, rt: *Runtime, pin: updates.Release, key: std.crypto.sign.Ed25519.PublicKey) !void {
    if (!updates.plainVersion(pin.version)) return error.BadRelease;
    const manifest = try updates.fetchManifest(arena, client, pin, key);
    const dest = try std.fs.path.join(arena, &.{ rt.home, "parsers", pin.version, "bake" ++ exe_suffix });
    try updates.install(arena, io, client, pin, manifest, parser_asset, dest);
    if (rt.parser_path) |old| {
        gpa.free(old);
        gpa.free(rt.parser_version);
    }
    rt.parser_path = try gpa.dupe(u8, dest);
    rt.parser_version = try gpa.dupe(u8, pin.version);
    std.log.info("parsing with {s} from now on", .{pin.version});
}

/// Fetches the pinned worker, puts it in place of this one and exits for it to be started
fn updateWorker(arena: Allocator, io: Io, client: *std.http.Client, rt: Runtime, pin: updates.Release, key: std.crypto.sign.Ed25519.PublicKey) !void {
    if (!updates.plainVersion(pin.version)) return error.BadRelease;
    const manifest = try updates.fetchManifest(arena, client, pin, key);
    const staged = try std.fs.path.join(arena, &.{ rt.home, "updates", pin.version, worker_asset });
    try updates.install(arena, io, client, pin, manifest, worker_asset, staged);
    try updates.swapIn(arena, io, rt.exe, staged, try rt.pendingPath(arena), .{ .from = version, .to = pin.version });
    std.log.info("updated to {s}: restarting", .{pin.version});
    std.process.exit(restart_code);
}

fn isBad(arena: Allocator, io: Io, rt: Runtime, v: []const u8) bool {
    const text = Io.Dir.cwd().readFileAlloc(io, rt.badPath(arena) catch return false, arena, .limited(256)) catch return false;

    return std.mem.eql(u8, std.mem.trim(u8, text, " \r\n"), v);
}

/// A worker just put in place by an update gets updates.max_starts starts to reach the server; past that
/// the one it replaced comes back, and its version is kept from being installed again
fn checkTrial(arena: Allocator, io: Io, rt: *Runtime) !void {
    const path = try rt.pendingPath(arena);
    const pending = updates.readPending(arena, io, path);
    switch (updates.trial(pending, version)) {
        .none => {},
        .stale => Io.Dir.cwd().deleteFile(io, path) catch {},
        .start => {
            const p = pending.?;
            try updates.writePending(arena, io, path, .{ .from = p.from, .to = p.to, .starts = p.starts + 1 });
            rt.on_trial = true;
        },
        .roll_back => {
            const p = pending.?;
            std.log.err("{s} didn't reach the server in {d} starts: going back to {s}", .{ version, p.starts, p.from });
            try Io.Dir.cwd().writeFile(io, .{ .sub_path = try rt.badPath(arena), .data = version });
            Io.Dir.cwd().deleteFile(io, path) catch {};
            updates.rollBack(arena, io, rt.exe) catch |err| {
                std.log.err("can't go back to {s} ({s}): staying on {s}", .{ p.from, @errorName(err), version });

                return;
            };
            std.process.exit(restart_code);
        },
    }
}

fn endTrial(arena: Allocator, io: Io, rt: *Runtime) void {
    rt.on_trial = false;
    Io.Dir.cwd().deleteFile(io, rt.pendingPath(arena) catch return) catch {};
    Io.Dir.cwd().deleteFile(io, std.fmt.allocPrint(arena, "{s}.old", .{rt.exe}) catch return) catch {};
    Io.Dir.cwd().deleteTree(io, std.fs.path.join(arena, &.{ rt.home, "updates" }) catch return) catch {};
    std.log.info("now running {s}", .{version});
}

/// What `bake version` says: the parser's .curves format
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
