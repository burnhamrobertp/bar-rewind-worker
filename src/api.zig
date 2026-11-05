//! The server's worker API (bar-rewind-server's server/workers.py): JSON posts carrying the worker's
//! token, and the presigned R2 URLs it hands out for downloads and uploads. Every request gives up once
//! it has moved no bytes for stall_seconds, so a connection that silently died can't hang the worker.

const std = @import("std");

const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const stall_seconds = 60;
const get_attempts = 3;

pub const Reply = struct {
    status: u16,
    body: []const u8,

    pub fn parse(reply: Reply, comptime T: type, arena: Allocator) !T {
        return std.json.parseFromSliceLeaky(T, arena, reply.body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
    }
};

pub const Api = struct {
    client: *std.http.Client,
    base: []const u8,
    token: ?[]const u8 = null,

    pub fn post(api: *Api, arena: Allocator, path: []const u8, body: anytype) !Reply {
        const url = try std.fmt.allocPrint(arena, "{s}{s}", .{ std.mem.trimEnd(u8, api.base, "/"), path });
        const json = try std.json.Stringify.valueAlloc(arena, body, .{});
        const auth = if (api.token) |t| try std.fmt.allocPrint(arena, "Bearer {s}", .{t}) else null;
        var progress: Progress = .init(api.client.io);

        return guarded(Reply, api.client.io, &progress, postBlocking, .{ api.client, arena, url, json, auth });
    }
};

fn postBlocking(client: *std.http.Client, arena: Allocator, url: []const u8, json: []const u8, auth: ?[]const u8) anyerror!Reply {
    var out: Io.Writer.Allocating = .init(arena);
    const status = try exchange(client, .POST, url, json, .{
        .content_type = .{ .override = "application/json" },
        .authorization = if (auth) |a| .{ .override = a } else .omit,
    }, &out.writer);

    return .{ .status = status, .body = out.written() };
}

/// Client.fetch, minus two traps: canceling it mid-body panics inside it, and a pooled connection the far
/// end dropped without a word can hang it, so every request here gets a connection of its own
fn exchange(client: *std.http.Client, method: std.http.Method, url: []const u8, payload: ?[]const u8,
            headers: std.http.Client.Request.Headers, out: *Io.Writer) !u16 {
    var plain = headers;
    plain.accept_encoding = .omit;
    var req = try client.request(method, try std.Uri.parse(url), .{
        .redirect_behavior = if (payload == null) @fromBackingInt(@intCast(3)) else .unhandled,
        .keep_alive = false,
        .headers = plain,
    });
    defer req.deinit();
    if (payload) |body| {
        req.transfer_encoding = .{ .content_length = body.len };
        var sending = try req.sendBodyUnflushed(&.{});
        try sending.writer.writeAll(body);
        try sending.end();
        try req.connection.?.flush();
    } else try req.sendBodiless();

    var redirect_buffer: [8 * 1024]u8 = undefined;
    var response = try req.receiveHead(if (payload == null) &redirect_buffer else &.{});
    if (response.head.content_encoding != .identity) return error.UnexpectedEncoding;
    var transfer_buffer: [64]u8 = undefined;
    _ = response.reader(&transfer_buffer).streamRemaining(out) catch |err| switch (err) {
        error.ReadFailed => return response.bodyErr() orelse error.ReadFailed,
        else => |e| return e,
    };

    return @intFromEnum(response.head.status);
}

pub const Header = struct { name: []const u8, value: []const u8 };

/// GET into memory, trying again on a failure or anything but 200
pub fn getText(client: *std.http.Client, io: Io, arena: Allocator, url: []const u8) !Reply {
    var attempt: u32 = 1;
    while (true) : (attempt += 1) {
        var out: Io.Writer.Allocating = .init(arena);
        var progress: Progress = .init(io);
        if (guarded(u16, io, &progress, getBlocking, .{ client, url, &out.writer, &progress })) |status| {
            if (status == 200 or attempt == get_attempts) return .{ .status = status, .body = out.written() };
        } else |err| {
            if (attempt == get_attempts) return err;
        }
        try backOff(io, attempt);
    }
}

/// GET into a file, trying again on a failure or anything but 200. Returns the last status.
pub fn download(client: *std.http.Client, io: Io, url: []const u8, path: []const u8, executable: bool) !u16 {
    var attempt: u32 = 1;
    while (true) : (attempt += 1) {
        if (downloadOnce(client, io, url, path, executable)) |status| {
            if (status == 200 or attempt == get_attempts) return status;
            std.log.info("downloading from {s} again: it answered {d}", .{ hostOf(url), status });
        } else |err| {
            if (attempt == get_attempts) return err;
            std.log.info("downloading from {s} again: {s}", .{ hostOf(url), @errorName(err) });
        }
        try backOff(io, attempt);
    }
}

fn downloadOnce(client: *std.http.Client, io: Io, url: []const u8, path: []const u8, executable: bool) !u16 {
    const file = try Io.Dir.cwd().createFile(io, path, .{ .permissions = if (executable) .executable_file else .default_file });
    defer file.close(io);
    var buffer: [1 << 16]u8 = undefined;
    var writer = file.writer(io, &buffer);
    var progress: Progress = .init(io);
    const status = try guarded(u16, io, &progress, getBlocking, .{ client, url, &writer.interface, &progress });
    try writer.interface.flush();

    return status;
}

fn getBlocking(client: *std.http.Client, url: []const u8, out: *Io.Writer, progress: *Progress) anyerror!u16 {
    var buffer: [1 << 12]u8 = undefined;
    var counted = progress.writer(out, &buffer);
    const status = try exchange(client, .GET, url, null, .{}, &counted.writer);
    try counted.writer.flush();

    return status;
}

/// PUT the file at `path` to a presigned URL, with the headers its signature covers
pub fn upload(client: *std.http.Client, io: Io, arena: Allocator, url: []const u8, path: []const u8, headers: []const Header) !u16 {
    var progress: Progress = .init(io);

    return guarded(u16, io, &progress, uploadBlocking, .{ client, io, arena, url, path, headers, &progress });
}

fn uploadBlocking(client: *std.http.Client, io: Io, arena: Allocator, url: []const u8, path: []const u8, headers: []const Header, progress: *Progress) anyerror!u16 {
    const file = try Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const size = try file.length(io);

    var content_type: ?[]const u8 = null;
    var extra: std.ArrayList(std.http.Header) = .empty;
    for (headers) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "content-type")) content_type = h.value else try extra.append(arena, .{ .name = h.name, .value = h.value });
    }
    var req = try client.request(.PUT, try std.Uri.parse(url), .{
        .redirect_behavior = .unhandled,
        .keep_alive = false,
        .headers = .{ .content_type = if (content_type) |t| .{ .override = t } else .omit, .accept_encoding = .omit },
        .extra_headers = extra.items,
    });
    defer req.deinit();
    req.transfer_encoding = .{ .content_length = size };
    var body_buffer: [1 << 16]u8 = undefined;
    var body = try req.sendBodyUnflushed(&body_buffer);
    var read_buffer: [1 << 16]u8 = undefined;
    var reader = file.reader(io, &read_buffer);
    var counted_buffer: [1 << 12]u8 = undefined;
    var counted = progress.writer(&body.writer, &counted_buffer);
    _ = try reader.interface.streamRemaining(&counted.writer);
    try counted.writer.flush();
    try body.end();
    try req.connection.?.flush();
    var response = try req.receiveHead(&.{});
    _ = response.reader(&.{}).discardRemaining() catch {};

    return @intFromEnum(response.head.status);
}

/// When bytes last moved, for the watchdog
const Progress = struct {
    io: Io,
    last_ms: std.atomic.Value(i64),
    limit_ms: i64 = stall_seconds * 1000,

    fn init(io: Io) Progress {
        return .{ .io = io, .last_ms = .init(nowMs(io)) };
    }

    /// Passes everything through to `out`, noting each write as progress
    fn writer(progress: *Progress, out: *Io.Writer, buffer: []u8) Io.Writer.Hashed(Tick) {
        return .initHasher(out, .{ .progress = progress }, buffer);
    }

    const Tick = struct {
        progress: *Progress,

        pub fn update(tick: *Tick, bytes: []const u8) void {
            _ = bytes;
            tick.progress.last_ms.store(nowMs(tick.progress.io), .monotonic);
        }
    };
};

fn nowMs(io: Io) i64 {
    return Io.Timestamp.now(io, .awake).toMilliseconds();
}

fn watch(progress: *Progress) Io.Cancelable!void {
    while (true) {
        try progress.io.sleep(.fromMilliseconds(@min(5000, @divTrunc(progress.limit_ms, 4))), .awake);
        if (nowMs(progress.io) - progress.last_ms.load(.monotonic) > progress.limit_ms) return;
    }
}

/// Runs `function` until it finishes, or until `progress` stands still for stall_seconds and it's canceled
fn guarded(comptime T: type, io: Io, progress: *Progress, function: anytype, args: anytype) anyerror!T {
    const Outcome = union(enum) { finished: anyerror!T, stalled: Io.Cancelable!void };
    var buffer: [2]Outcome = undefined;
    var select: Io.Select(Outcome) = .init(io, &buffer);
    defer select.cancelDiscard();
    select.concurrent(.finished, function, args) catch return @call(.auto, function, args);
    select.concurrent(.stalled, watch, .{progress}) catch {};

    return switch (try select.await()) {
        .finished => |result| result,
        .stalled => error.Stalled,
    };
}

fn backOff(io: Io, attempt: u32) Io.Cancelable!void {
    try io.sleep(.fromSeconds(2 * attempt), .awake);
}

fn hostOf(url: []const u8) []const u8 {
    const uri = std.Uri.parse(url) catch return "?";
    const host = uri.host orelse return "?";

    return switch (host) {
        inline else => |h| h,
    };
}

fn hang(io: Io) anyerror!u16 {
    try io.sleep(.fromSeconds(3600), .awake);

    return 200;
}

fn answer() anyerror!u16 {
    return 204;
}

test "a call that moves nothing is given up on, one that finishes isn't" {
    const io = std.testing.io;
    var progress: Progress = .init(io);
    progress.limit_ms = 200;
    try std.testing.expectError(error.Stalled, guarded(u16, io, &progress, hang, .{io}));

    var quick: Progress = .init(io);
    try std.testing.expectEqual(204, try guarded(u16, io, &quick, answer, .{}));
}

fn trickle(io: Io, server: *Io.net.Server) void {
    const stream = server.accept(io) catch return;
    defer stream.close(io);
    var buffer: [256]u8 = undefined;
    var w = stream.writer(io, &buffer);
    w.interface.writeAll("HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\nab") catch return;
    w.interface.flush() catch return;
    io.sleep(.fromSeconds(3600), .awake) catch {};
}

test "a response that stops halfway is given up on" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var address = try Io.net.IpAddress.parse("127.0.0.1", 0);
    var server = try address.listen(io, .{});
    defer server.deinit(io);
    var serving = try io.concurrent(trickle, .{ io, &server });
    defer serving.cancel(io);

    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    const url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/", .{server.socket.address.getPort()});
    defer gpa.free(url);
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var progress: Progress = .init(io);
    progress.limit_ms = 300;
    try std.testing.expectError(error.Stalled, guarded(u16, io, &progress, getBlocking, .{ &client, url, &out.writer, &progress }));
}
