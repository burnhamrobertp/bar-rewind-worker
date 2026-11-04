//! What the worker keeps between runs: which server it enrolled with, and its id and token there. On
//! Windows the token is sealed with DPAPI, so only this Windows account on this machine can read it back.

const std = @import("std");
const builtin = @import("builtin");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const windows = builtin.os.tag == .windows;

pub const State = struct {
    server: []const u8,
    worker_id: []const u8,
    token: []const u8,
};

const Stored = struct { server: []const u8, worker_id: []const u8, token: []const u8, sealed: bool = false };

pub fn load(io: Io, arena: Allocator, path: []const u8) !?State {
    const text = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 16)) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    const stored = std.json.parseFromSliceLeaky(Stored, arena, text, .{ .ignore_unknown_fields = true }) catch return null;
    const token = if (windows and stored.sealed) unseal(arena, stored.token) catch return null else stored.token;

    return .{ .server = stored.server, .worker_id = stored.worker_id, .token = token };
}

pub fn save(io: Io, arena: Allocator, path: []const u8, state: State) !void {
    const stored: Stored = if (windows)
        .{ .server = state.server, .worker_id = state.worker_id, .token = try seal(arena, state.token), .sealed = true }
    else
        .{ .server = state.server, .worker_id = state.worker_id, .token = state.token };
    const json = try std.json.Stringify.valueAlloc(arena, stored, .{ .whitespace = .indent_2 });
    const part = try std.fmt.allocPrint(arena, "{s}.part", .{path});
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = part, .data = json, .flags = if (windows) .{} else .{ .permissions = .fromMode(0o600) } });
    try Io.Dir.cwd().rename(part, Io.Dir.cwd(), path, io);
}

pub fn forget(io: Io, path: []const u8) void {
    Io.Dir.cwd().deleteFile(io, path) catch {};
}

fn seal(arena: Allocator, token: []const u8) ![]const u8 {
    var in: Blob = .{ .size = @intCast(token.len), .data = @constCast(token.ptr) };
    var out: Blob = .{ .size = 0, .data = null };
    if (!win32.CryptProtectData(&in, null, null, null, null, ui_forbidden, &out).toBool()) return error.SealFailed;
    defer _ = win32.LocalFree(out.data);
    const sealed = out.data.?[0..out.size];
    const text = try arena.alloc(u8, std.base64.standard.Encoder.calcSize(sealed.len));

    return std.base64.standard.Encoder.encode(text, sealed);
}

fn unseal(arena: Allocator, text: []const u8) ![]const u8 {
    const sealed = try arena.alloc(u8, try std.base64.standard.Decoder.calcSizeForSlice(text));
    try std.base64.standard.Decoder.decode(sealed, text);
    var in: Blob = .{ .size = @intCast(sealed.len), .data = sealed.ptr };
    var out: Blob = .{ .size = 0, .data = null };
    if (!win32.CryptUnprotectData(&in, null, null, null, null, ui_forbidden, &out).toBool()) return error.UnsealFailed;
    defer _ = win32.LocalFree(out.data);

    return arena.dupe(u8, out.data.?[0..out.size]);
}

const Blob = extern struct { size: u32, data: ?[*]u8 };
const ui_forbidden = 0x1;

const win32 = if (windows) struct {
    extern "crypt32" fn CryptProtectData(in: *Blob, description: ?[*:0]const u16, entropy: ?*Blob, reserved: ?*anyopaque, prompt: ?*anyopaque, flags: u32, out: *Blob) callconv(.winapi) std.os.windows.BOOL;
    extern "crypt32" fn CryptUnprotectData(in: *Blob, description: ?*?[*:0]u16, entropy: ?*Blob, reserved: ?*anyopaque, prompt: ?*anyopaque, flags: u32, out: *Blob) callconv(.winapi) std.os.windows.BOOL;
    extern "kernel32" fn LocalFree(memory: ?*anyopaque) callconv(.winapi) ?*anyopaque;
} else struct {};

test "a saved state reads back, the token sealed on Windows" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/worker.json", .{tmp.sub_path});
    try save(std.testing.io, gpa, path, .{ .server = "https://rewind.example", .worker_id = "abc", .token = "secret-token" });
    const text = try tmp.dir.readFileAlloc(std.testing.io, "worker.json", gpa, .limited(1 << 16));
    if (windows) try std.testing.expect(std.mem.indexOf(u8, text, "secret-token") == null);
    const back = (try load(std.testing.io, gpa, path)).?;
    try std.testing.expectEqualStrings("secret-token", back.token);
    try std.testing.expectEqualStrings("abc", back.worker_id);
}
