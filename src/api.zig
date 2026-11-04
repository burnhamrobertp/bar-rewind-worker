//! The server's worker API (bar-rewind-server's server/workers.py): JSON posts carrying the worker's
//! token, and the presigned R2 URLs it hands out for downloads and uploads.

const std = @import("std");

const Io = std.Io;
const Allocator = std.mem.Allocator;

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
        var out: Io.Writer.Allocating = .init(arena);
        const result = try api.client.fetch(.{
            .location = .{ .url = url },
            .method = .POST,
            .payload = json,
            .headers = .{
                .content_type = .{ .override = "application/json" },
                .authorization = if (auth) |a| .{ .override = a } else .omit,
            },
            .response_writer = &out.writer,
        });

        return .{ .status = @intFromEnum(result.status), .body = out.written() };
    }
};

pub const Header = struct { name: []const u8, value: []const u8 };

pub fn download(client: *std.http.Client, io: Io, url: []const u8, path: []const u8) !u16 {
    const file = try Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    var buffer: [1 << 16]u8 = undefined;
    var writer = file.writer(io, &buffer);
    const result = try client.fetch(.{ .location = .{ .url = url }, .response_writer = &writer.interface });
    try writer.interface.flush();

    return @intFromEnum(result.status);
}

/// PUT the file at `path` to a presigned URL, with the headers its signature covers
pub fn upload(client: *std.http.Client, io: Io, arena: Allocator, url: []const u8, path: []const u8, headers: []const Header) !u16 {
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
    _ = try reader.interface.streamRemaining(&body.writer);
    try body.end();
    try req.connection.?.flush();
    var response = try req.receiveHead(&.{});
    _ = response.reader(&.{}).discardRemaining() catch {};

    return @intFromEnum(response.head.status);
}
