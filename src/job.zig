//! One claimed job, start to end: fetch the demo, run `bake parse` on it with progress going back to the
//! server, gzip and upload the .curves and the log, and report the job done or failed.

const std = @import("std");
const builtin = @import("builtin");
const api = @import("api.zig");
const housekeeping = @import("housekeeping.zig");
const system = @import("system.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const Claim = struct {
    job: struct { id: []const u8, demo_url: []const u8, duration_ms: u64 = 0, attempt: u32 = 1 },
    uploads: Uploads,
};

pub const Uploads = struct {
    curves: Upload,
    log: Upload,

    pub const Upload = struct { url: []const u8, headers: std.json.ArrayHashMap([]const u8) };
};

pub const Paths = struct { bake: []const u8, bar: []const u8, work: []const u8 };

const progress_seconds = 15;
const events_listed = 200;

/// What the progress thread and the parse share
const Shared = struct {
    mutex: Io.Mutex = .init,
    stage: [256]u8 = undefined,
    stage_len: usize = 0,
    pct: i64 = 0,
    peak_mb: u64 = 0,
    done: bool = false,
    dropped: std.atomic.Value(bool) = .init(false),
    tree: ?*system.Tree = null,

    fn set(s: *Shared, io: Io, pct: i64, stage: []const u8) void {
        s.mutex.lockUncancelable(io);
        defer s.mutex.unlock(io);
        const n = @min(stage.len, s.stage.len);
        @memcpy(s.stage[0..n], stage[0..n]);
        s.stage_len = n;
        s.pct = pct;
    }

    fn notePeak(s: *Shared, io: Io, mb: u64) void {
        s.mutex.lockUncancelable(io);
        defer s.mutex.unlock(io);
        s.peak_mb = @max(s.peak_mb, mb);
    }

    fn peak(s: *Shared, io: Io) u64 {
        s.mutex.lockUncancelable(io);
        defer s.mutex.unlock(io);

        return s.peak_mb;
    }

    /// The job went to someone else: stop its parse, whatever it's in the middle of
    fn drop(s: *Shared, io: Io) void {
        s.mutex.lockUncancelable(io);
        defer s.mutex.unlock(io);
        s.dropped.store(true, .release);
        if (s.tree) |tree| tree.terminate();
    }
};

pub fn run(gpa: Allocator, io: Io, server: *api.Api, paths: Paths, claim: Claim) !void {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const id = claim.job.id;
    if (id.len != 32) return error.BadJob;
    for (id) |c| if (!std.ascii.isHex(c)) return error.BadJob;

    const work = paths.work;
    Io.Dir.cwd().deleteTree(io, work) catch {};
    try Io.Dir.cwd().createDirPath(io, work);
    const demo = try std.fs.path.join(arena, &.{ work, "match.sdfz" });
    const curves = try std.fs.path.join(arena, &.{ work, "match.curves" });
    const packed_path = try std.fs.path.join(arena, &.{ work, "match.curves.gz" });
    const log = try std.fs.path.join(arena, &.{ work, "parse.log" });
    const stderr_path = try std.fs.path.join(arena, &.{ work, "bake.log" });

    var shared: Shared = .{};
    shared.set(io, 0, "downloading the replay");
    const reporter = try std.Thread.spawn(.{}, report, .{ gpa, io, server, id, &shared });
    defer reporter.join();
    defer {
        shared.mutex.lockUncancelable(io);
        shared.done = true;
        shared.mutex.unlock(io);
    }

    const outcome = parse(arena, io, server.client, paths, claim, &shared, .{ .demo = demo, .curves = curves, .log = log, .stderr = stderr_path });
    if (shared.dropped.load(.acquire)) return;

    const memory = system.memory(io);
    const peak = shared.peak(io);
    uploadLog(arena, io, server, claim.uploads.log, &.{ stderr_path, log });
    const delivered = if (outcome) |_| deliver(arena, io, server, paths, id, claim, &shared, curves, packed_path, peak) else |err| err;
    if (delivered) |_| {} else |err| {
        const message = failure orelse @errorName(err);
        const oom = (memory.total_mb > 0 and peak * 100 >= memory.total_mb * 85) or
            std.ascii.findIgnoreCase(message, "out of memory") != null or std.mem.indexOf(u8, message, "bad_alloc") != null;
        std.log.warn("job {s} failed: {s}{s}", .{ id, message, if (oom) " (out of memory)" else "" });
        _ = server.post(arena, try std.fmt.allocPrint(arena, "/api/worker/jobs/{s}/fail", .{id}), .{
            .@"error" = message, .peak_mem_mb = peak, .out_of_memory = oom,
        }) catch |e| std.log.warn("could not report the failure: {s}", .{@errorName(e)});
    }
    Io.Dir.cwd().deleteTree(io, work) catch {};
}

/// The parsed replay up to the server: gzipped, uploaded, reported done
fn deliver(arena: Allocator, io: Io, server: *api.Api, paths: Paths, id: []const u8, claim: Claim, shared: *Shared,
           curves: []const u8, packed_path: []const u8, peak: u64) !void {
    shared.set(io, 100, "uploading");
    try gzipFile(io, curves, packed_path);
    try uploadCurves(arena, io, server, id, claim.uploads.curves, packed_path);
    if (engineOf(arena, io, paths.bake, curves)) |engine| housekeeping.markUsed(arena, io, paths.bar, engine, Io.Timestamp.now(io, .real).toSeconds());
    const events = listEvents(arena, io, paths.bake, curves);
    const shown = events[0..@min(events.len, events_listed)];
    const reply = try server.post(arena, try std.fmt.allocPrint(arena, "/api/worker/jobs/{s}/done", .{id}), .{
        .size = try fileSize(io, curves), .packed_size = try fileSize(io, packed_path), .curves_version = try curvesVersion(io, curves),
        .event_count = events.len, .events = shown, .peak_mem_mb = peak,
    });
    if (reply.status != 200) {
        failure = try std.fmt.allocPrint(arena, "the server refused the result ({d}): {s}", .{ reply.status, reply.body });

        return error.DoneRefused;
    }
}

/// Why the last parse failed, in words for the job's error
threadlocal var failure: ?[]const u8 = null;

const Files = struct { demo: []const u8, curves: []const u8, log: []const u8, stderr: []const u8 };

fn parse(arena: Allocator, io: Io, client: *std.http.Client, paths: Paths, claim: Claim, shared: *Shared, files: Files) !void {
    failure = null;
    const status = try api.download(client, io, claim.job.demo_url, files.demo, false);
    if (status != 200) {
        failure = try std.fmt.allocPrint(arena, "the demo download answered {d}", .{status});
        return error.DownloadFailed;
    }

    const stderr = try Io.Dir.cwd().createFile(io, files.stderr, .{});
    defer stderr.close(io);
    var child = try std.process.spawn(io, .{
        .argv = &.{ paths.bake, "parse", files.demo, files.curves, "--bar", paths.bar, "--log", files.log },
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .{ .file = stderr },
        .create_no_window = true,
        .pgid = if (builtin.os.tag == .windows) null else 0,
    });
    var tree = system.Tree.watch(&child);
    shared.mutex.lockUncancelable(io);
    shared.tree = &tree;
    if (shared.dropped.load(.acquire)) tree.terminate();
    shared.mutex.unlock(io);
    defer {
        shared.mutex.lockUncancelable(io);
        shared.tree = null;
        shared.mutex.unlock(io);
        tree.close();
    }

    const Line = struct { pct: i64 = 0, text: []const u8 = "", @"error": ?[]const u8 = null };
    var buffer: [64 << 10]u8 = undefined;
    var reader = child.stdout.?.readerStreaming(io, &buffer);
    var last_error: ?[]const u8 = null;
    while (reader.interface.takeDelimiter('\n') catch null) |raw| {
        const line = std.json.parseFromSliceLeaky(Line, arena, std.mem.trim(u8, raw, " \r"), .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch continue;
        if (line.@"error") |e| last_error = e else shared.set(io, line.pct, line.text);
        shared.notePeak(io, tree.peakMb(io, arena));
    }
    shared.notePeak(io, tree.peakMb(io, arena));
    const term = try child.wait(io);
    if (shared.dropped.load(.acquire)) return error.Dropped;
    if (term == .exited and term.exited == 0) return;
    failure = last_error orelse try std.fmt.allocPrint(arena, "bake parse {f}", .{term});

    return error.ParseFailed;
}

/// Every progress_seconds: the latest stage, which is also the job's heartbeat. A 409 or 401 means the job
/// isn't ours any more: the parse stops.
fn report(gpa: Allocator, io: Io, server: *api.Api, id: []const u8, shared: *Shared) void {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    while (true) {
        _ = arena_state.reset(.retain_capacity);
        const arena = arena_state.allocator();
        shared.mutex.lockUncancelable(io);
        const done = shared.done;
        const stage = arena.dupe(u8, shared.stage[0..shared.stage_len]) catch "";
        const pct = shared.pct;
        const peak_mb = shared.peak_mb;
        shared.mutex.unlock(io);
        if (done) return;
        const path = std.fmt.allocPrint(arena, "/api/worker/jobs/{s}/progress", .{id}) catch return;
        if (server.post(arena, path, .{ .stage = stage, .pct = pct, .peak_mem_mb = peak_mb })) |reply| {
            if (reply.status == 409 or reply.status == 401) {
                std.log.warn("the server gave job {s} to another worker: stopping it", .{id});
                shared.drop(io);
                return;
            }
        } else |err| std.log.warn("progress report failed: {s}", .{@errorName(err)});
        var waited: u32 = 0;
        while (waited < progress_seconds * 4) : (waited += 1) {
            io.sleep(.fromMilliseconds(250), .awake) catch return;
            shared.mutex.lockUncancelable(io);
            const finished = shared.done;
            shared.mutex.unlock(io);
            if (finished) return;
        }
    }
}

fn fileSize(io: Io, path: []const u8) !u64 {
    const file = try Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    return file.length(io);
}

/// The format version in a .curves header: "BRC1", then a little-endian u32
fn curvesVersion(io: Io, path: []const u8) !u32 {
    var head: [8]u8 = undefined;
    const got = try Io.Dir.cwd().readFile(io, path, &head);
    if (got.len < 8 or !std.mem.eql(u8, got[0..4], "BRC1")) return error.NotCurves;

    return std.mem.readInt(u32, got[4..8], .little);
}

fn gzipFile(io: Io, from: []const u8, to: []const u8) !void {
    const in_file = try Io.Dir.cwd().openFile(io, from, .{});
    defer in_file.close(io);
    const out_file = try Io.Dir.cwd().createFile(io, to, .{});
    defer out_file.close(io);
    var read_buffer: [1 << 16]u8 = undefined;
    var reader = in_file.reader(io, &read_buffer);
    var write_buffer: [1 << 16]u8 = undefined;
    var writer = out_file.writer(io, &write_buffer);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var gz = try std.compress.flate.Compress.init(&writer.interface, &window, .gzip, .level_6);
    _ = try reader.interface.streamRemaining(&gz.writer);
    try gz.finish();
    try writer.interface.flush();
}

fn headersOf(arena: Allocator, upload: Uploads.Upload) ![]const api.Header {
    var out: std.ArrayList(api.Header) = .empty;
    for (upload.headers.map.keys(), upload.headers.map.values()) |k, v| try out.append(arena, .{ .name = k, .value = v });

    return out.items;
}

/// A presigned URL lasts 3 hours: past that, the server signs a fresh one
fn uploadCurves(arena: Allocator, io: Io, server: *api.Api, id: []const u8, first: Uploads.Upload, path: []const u8) !void {
    var upload = first;
    for (0..2) |attempt| {
        const status = api.upload(server.client, io, arena, upload.url, path, try headersOf(arena, upload)) catch 0;
        if (status == 200) return;
        std.log.warn("the .curves upload answered {d}", .{status});
        if (attempt == 1) break;
        const reply = try server.post(arena, try std.fmt.allocPrint(arena, "/api/worker/jobs/{s}/uploads", .{id}), .{});
        if (reply.status != 200) return error.UploadFailed;
        upload = (try reply.parse(struct { uploads: Uploads }, arena)).uploads.curves;
    }

    return error.UploadFailed;
}

/// bake's own messages, then the engine's: what the job's Log button shows
fn uploadLog(arena: Allocator, io: Io, server: *api.Api, upload: Uploads.Upload, parts: []const []const u8) void {
    const joined = std.fs.path.join(arena, &.{ std.fs.path.dirname(parts[0]) orelse ".", "upload.log" }) catch return;
    var text: Io.Writer.Allocating = .init(arena);
    for (parts) |p| {
        const data = Io.Dir.cwd().readFileAlloc(io, p, arena, .limited(64 << 20)) catch continue;
        text.writer.print("---- {s} ----\n", .{std.fs.path.basename(p)}) catch return;
        text.writer.writeAll(data) catch return;
        text.writer.writeAll("\n") catch return;
    }
    Io.Dir.cwd().writeFile(io, .{ .sub_path = joined, .data = text.written() }) catch return;
    const status = api.upload(server.client, io, arena, upload.url, joined, headersOf(arena, upload) catch return) catch |err| {
        std.log.warn("the log upload failed: {s}", .{@errorName(err)});

        return;
    };
    if (status != 200) std.log.warn("the log upload answered {d}", .{status});
}

/// The engine a .curves was recorded on, from `bake info`'s engine= line
fn engineOf(arena: Allocator, io: Io, bake: []const u8, curves: []const u8) ?[]const u8 {
    const result = std.process.run(arena, io, .{ .argv = &.{ bake, "info", curves }, .create_no_window = true }) catch return null;
    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    while (lines.next()) |line| if (std.mem.startsWith(u8, line, "engine=")) return std.mem.trim(u8, line["engine=".len..], " \r");

    return null;
}

const Event = struct { f: u64 = 0, kind: []const u8 = "", player: []const u8 = "", text: []const u8 = "" };

fn listEvents(arena: Allocator, io: Io, bake: []const u8, curves: []const u8) []const Event {
    const result = std.process.run(arena, io, .{ .argv = &.{ bake, "events", curves }, .create_no_window = true }) catch return &.{};
    if (result.term != .exited or result.term.exited != 0) return &.{};

    return std.json.parseFromSliceLeaky([]const Event, arena, result.stdout, .{ .ignore_unknown_fields = true }) catch &.{};
}
