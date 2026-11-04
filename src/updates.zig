//! Updates from signed releases. The server pins the parser (a BAR-Rewind release) and the worker release
//! to run; a release counts only when its manifest.json carries a valid signature by the release key built
//! into this worker, names the pinned version, and lists the file with the size and hash that arrived.
//! An admin may pin an older release to roll back, so the pin, not the newest version, decides.

const std = @import("std");
const builtin = @import("builtin");
const api = @import("api.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const Ed25519 = std.crypto.sign.Ed25519;
const windows = builtin.os.tag == .windows;

pub const Release = struct { version: []const u8, manifest: []const u8 };

pub const Manifest = struct {
    version: []const u8,
    curves_version: u32 = 0,
    files: []const File,

    pub const File = struct { name: []const u8, size: u64, sha256: []const u8 };
};

/// Exactly `n` bytes of hex: hexToBytes alone takes shorter input and leaves the rest undefined
pub fn parseHex(comptime n: usize, text: []const u8) error{BadHex}![n]u8 {
    var out: [n]u8 = undefined;
    const got = std.fmt.hexToBytes(&out, std.mem.trim(u8, text, " \r\n")) catch return error.BadHex;
    if (got.len != n) return error.BadHex;

    return out;
}

/// The manifest's exact bytes against its signature, then its version against the pin
pub fn checkManifest(arena: Allocator, json: []const u8, sig_hex: []const u8, key: Ed25519.PublicKey, pinned: []const u8) !Manifest {
    const sig = parseHex(Ed25519.Signature.encoded_length, sig_hex) catch return error.BadSignature;
    Ed25519.Signature.fromBytes(sig).verify(json, key) catch return error.BadSignature;
    const manifest = std.json.parseFromSliceLeaky(Manifest, arena, json, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch
        return error.BadManifest;
    if (!std.mem.eql(u8, manifest.version, pinned)) return error.NotThePinnedRelease;

    return manifest;
}

fn fetchText(arena: Allocator, client: *std.http.Client, url: []const u8) ![]const u8 {
    var out: Io.Writer.Allocating = .init(arena);
    const result = try client.fetch(.{ .location = .{ .url = url }, .response_writer = &out.writer });
    if (result.status != .ok) return error.ReleaseUnavailable;

    return out.written();
}

pub fn fetchManifest(arena: Allocator, client: *std.http.Client, release: Release, key: Ed25519.PublicKey) !Manifest {
    const json = try fetchText(arena, client, release.manifest);
    const sig = try fetchText(arena, client, try std.fmt.allocPrint(arena, "{s}.sig", .{release.manifest}));

    return checkManifest(arena, json, sig, key, release.version);
}

fn sha256Hex(io: Io, path: []const u8) ![64]u8 {
    const file = try Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var buffer: [1 << 16]u8 = undefined;
    var reader = file.reader(io, &buffer);
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    while (true) {
        const n = reader.interface.readSliceShort(&buffer) catch return error.ReadFailed;
        if (n == 0) break;
        hash.update(buffer[0..n]);
    }

    return std.fmt.bytesToHex(hash.finalResult(), .lower);
}

pub fn matches(io: Io, path: []const u8, entry: Manifest.File) bool {
    const file = Io.Dir.cwd().openFile(io, path, .{}) catch return false;
    const size = file.length(io) catch 0;
    file.close(io);
    if (size != entry.size) return false;
    const hash = sha256Hex(io, path) catch return false;

    return std.mem.eql(u8, &hash, entry.sha256);
}

/// Downloads `name` from the release beside its manifest to `dest`, which only ever holds a file that
/// matched the signed manifest
pub fn install(arena: Allocator, io: Io, client: *std.http.Client, release: Release, manifest: Manifest, name: []const u8, dest: []const u8) !void {
    const entry = for (manifest.files) |f| {
        if (std.mem.eql(u8, f.name, name)) break f;
    } else return error.NotInRelease;
    if (matches(io, dest, entry)) return;
    const base = release.manifest[0 .. (std.mem.lastIndexOfScalar(u8, release.manifest, '/') orelse return error.BadManifest) + 1];
    const part = try std.fmt.allocPrint(arena, "{s}.part", .{dest});
    if (std.fs.path.dirname(dest)) |dir| try Io.Dir.cwd().createDirPath(io, dir);
    const status = try api.download(client, io, try std.fmt.allocPrint(arena, "{s}{s}", .{ base, name }), part, true);
    if (status != 200) return error.ReleaseUnavailable;
    if (!matches(io, part, entry)) {
        Io.Dir.cwd().deleteFile(io, part) catch {};

        return error.FileDoesNotMatch;
    }
    try Io.Dir.cwd().rename(part, Io.Dir.cwd(), dest, io);
}

// the worker replacing itself -------------------------------------------------------------------------

/// What an update in progress leaves beside the worker: the version it came from and went to, and how
/// many starts the new one has had without reaching the server
pub const Pending = struct { from: []const u8, to: []const u8, starts: u32 = 0 };

/// Starts a new worker gets to reach the server before the old one comes back
pub const max_starts = 3;

/// Puts `staged` where the running worker is; the running one is kept as <exe>.old to come back to
pub fn swapIn(arena: Allocator, io: Io, exe: []const u8, staged: []const u8, pending_path: []const u8, pending: Pending) !void {
    const old = try std.fmt.allocPrint(arena, "{s}.old", .{exe});
    // the supervisor may still be running the last update's .old, which Windows won't delete: it moves aside
    Io.Dir.cwd().deleteFile(io, old) catch |err| switch (err) {
        error.FileNotFound => {},
        else => {
            const older = try std.fmt.allocPrint(arena, "{s}.older", .{exe});
            Io.Dir.cwd().deleteFile(io, older) catch {};
            try move(arena, io, old, older);
        },
    };
    // a running program can be renamed but not overwritten
    try move(arena, io, exe, old);
    Io.Dir.cwd().copyFile(staged, Io.Dir.cwd(), exe, io, .{}) catch |err| {
        move(arena, io, old, exe) catch {};

        return err;
    };
    try writePending(arena, io, pending_path, pending);
}

pub fn readPending(arena: Allocator, io: Io, path: []const u8) ?Pending {
    const text = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(4096)) catch return null;

    return std.json.parseFromSliceLeaky(Pending, arena, text, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch null;
}

pub fn writePending(arena: Allocator, io: Io, path: []const u8, pending: Pending) !void {
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = try std.json.Stringify.valueAlloc(arena, pending, .{}) });
}

/// The new worker failed to reach the server max_starts times: the old one goes back where it was
pub fn rollBack(arena: Allocator, io: Io, exe: []const u8) !void {
    const old = try std.fmt.allocPrint(arena, "{s}.old", .{exe});
    const bad = try std.fmt.allocPrint(arena, "{s}.bad", .{exe});
    Io.Dir.cwd().deleteFile(io, bad) catch {};
    try move(arena, io, exe, bad);
    move(arena, io, old, exe) catch |err| {
        move(arena, io, bad, exe) catch {};

        return err;
    };
}

/// A release name from the server becomes part of a path: letters, digits and . - _ only
pub fn plainVersion(v: []const u8) bool {
    if (v.len == 0 or v.len > 64 or v[0] == '.') return false;
    for (v) |c| if (!std.ascii.isAlphanumeric(c) and std.mem.indexOfScalar(u8, ".-_", c) == null) return false;

    return true;
}

pub const Trial = enum { none, stale, start, roll_back };

/// What a start does about an update left pending: nothing to do, a pending file from another version to
/// drop, another start on trial, or the trial used up
pub fn trial(pending: ?Pending, running: []const u8) Trial {
    const p = pending orelse return .none;
    if (!std.mem.eql(u8, p.to, running)) return .stale;

    return if (p.starts >= max_starts) .roll_back else .start;
}

test "trials count starts up to the limit, for the version the update went to" {
    try std.testing.expectEqual(Trial.none, trial(null, "v2"));
    try std.testing.expectEqual(Trial.stale, trial(.{ .from = "v1", .to = "v2" }, "v1"));
    try std.testing.expectEqual(Trial.start, trial(.{ .from = "v1", .to = "v2", .starts = max_starts - 1 }, "v2"));
    try std.testing.expectEqual(Trial.roll_back, trial(.{ .from = "v1", .to = "v2", .starts = max_starts }, "v2"));
}

test "release names can't become paths" {
    try std.testing.expect(plainVersion("v0.5.0"));
    try std.testing.expect(plainVersion("v1.2.3-rc_1"));
    for ([_][]const u8{ "", "..", ".hidden", "v1/../x", "v1\\x", "v 1", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" }) |bad| try std.testing.expect(!plainVersion(bad));
}

/// Windows renames a running program only through MoveFileEx: Zig's own rename asks for access the
/// running image's handle doesn't share
fn move(arena: Allocator, io: Io, from: []const u8, to: []const u8) !void {
    if (!windows) return Io.Dir.cwd().rename(from, Io.Dir.cwd(), to, io);
    const wide_from = try std.unicode.wtf8ToWtf16LeAllocZ(arena, from);
    const wide_to = try std.unicode.wtf8ToWtf16LeAllocZ(arena, to);
    if (!win32.MoveFileExW(wide_from, wide_to, 0).toBool()) return error.RenameFailed;
}

const win32 = if (windows) struct {
    extern "kernel32" fn MoveFileExW(from: [*:0]const u16, to: [*:0]const u16, flags: u32) callconv(.winapi) std.os.windows.BOOL;
} else struct {};

test "a manifest counts only signed by the key, for the pinned version" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    const pair = try Ed25519.KeyPair.generateDeterministic(@splat(7));
    const other = try Ed25519.KeyPair.generateDeterministic(@splat(8));
    const json = "{\"version\":\"v0.5.0\",\"curves_version\":11,\"files\":[{\"name\":\"bake.exe\",\"size\":4,\"sha256\":\"ab\"}]}";
    const sig = std.fmt.bytesToHex((try pair.sign(json, null)).toBytes(), .lower);

    const m = try checkManifest(gpa, json, &sig, pair.public_key, "v0.5.0");
    try std.testing.expectEqualStrings("bake.exe", m.files[0].name);
    try std.testing.expectError(error.NotThePinnedRelease, checkManifest(gpa, json, &sig, pair.public_key, "v0.6.0"));
    try std.testing.expectError(error.BadSignature, checkManifest(gpa, json, &sig, other.public_key, "v0.5.0"));
    try std.testing.expectError(error.BadSignature, checkManifest(gpa, json, sig[0..100], pair.public_key, "v0.5.0"));
    const forged = try std.mem.replaceOwned(u8, gpa, json, "\"size\":4", "\"size\":5");
    try std.testing.expectError(error.BadSignature, checkManifest(gpa, forged, &sig, pair.public_key, "v0.5.0"));
}

test "a file matches its entry only at the listed size and hash" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try tmp.dir.writeFile(io, .{ .sub_path = "bake", .data = "bake" });
    const path = try std.fmt.allocPrint(arena.allocator(), ".zig-cache/tmp/{s}/bake", .{tmp.sub_path});
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("bake", &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    try std.testing.expect(matches(io, path, .{ .name = "bake", .size = 4, .sha256 = &hex }));
    try std.testing.expect(!matches(io, path, .{ .name = "bake", .size = 5, .sha256 = &hex }));
    try std.testing.expect(!matches(io, path, .{ .name = "bake", .size = 4, .sha256 = &@as([64]u8, @splat('0')) }));
}

test "swapping in a new worker keeps the old one to roll back to" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    const dir = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try tmp.dir.writeFile(io, .{ .sub_path = "worker", .data = "old" });
    try tmp.dir.writeFile(io, .{ .sub_path = "staged", .data = "new" });
    const exe = try std.fs.path.join(gpa, &.{ dir, "worker" });
    const pending = try std.fs.path.join(gpa, &.{ dir, "pending.json" });
    try swapIn(gpa, io, exe, try std.fs.path.join(gpa, &.{ dir, "staged" }), pending, .{ .from = "v1", .to = "v2" });
    var buffer: [8]u8 = undefined;
    try std.testing.expectEqualStrings("new", try tmp.dir.readFile(io, "worker", &buffer));
    try std.testing.expectEqualStrings("v2", readPending(gpa, io, pending).?.to);
    try rollBack(gpa, io, exe);
    try std.testing.expectEqualStrings("old", try tmp.dir.readFile(io, "worker", &buffer));
}
