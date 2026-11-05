//! The server's parse widgets: extra widgets every parse runs, fetched from the server with the worker's
//! token. A worker reports the set's hash once it has it; the server gives jobs only to workers with the
//! current one.

const std = @import("std");

const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const File = struct { name: []const u8, text: []const u8 };

/// The server's hash of a set (server/widgets.py): each file's name and the sha256 of its text, in name
/// order, hashed again; empty for no widgets
pub fn digest(arena: Allocator, files: []File) ![]const u8 {
    if (files.len == 0) return "";
    std.mem.sort(File, files, {}, struct {
        fn lessThan(_: void, a: File, b: File) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lessThan);
    var listing: Io.Writer.Allocating = .init(arena);
    for (files) |f| {
        var hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(f.text, &hash, .{});
        try listing.writer.print("{s}\n{s}\n", .{ f.name, std.fmt.bytesToHex(hash, .lower) });
    }
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(listing.written(), &hash, .{});

    return arena.dupe(u8, &std.fmt.bytesToHex(hash, .lower));
}

/// What the server lets a widget be called, so no name can reach outside the widgets folder
pub fn validName(name: []const u8) bool {
    if (name.len < 5 or name.len > 68 or !std.mem.endsWith(u8, name, ".lua")) return false;
    for (name) |c| if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '.' and c != '-') return false;

    return !std.mem.eql(u8, name[0 .. name.len - 4], "..") and !std.mem.eql(u8, name[0 .. name.len - 4], ".");
}

test "the hash matches the server's, whatever order the files come in" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    var files = [_]File{ .{ .name = "b_widget.lua", .text = "-- two" }, .{ .name = "a_widget.lua", .text = "-- one" } };
    try std.testing.expectEqualStrings("a6fd87a8e4c61fba4f1d1a28d45cc028e54b34c679d5c4d1fc09be4d7789d288", try digest(arena_state.allocator(), &files));
    try std.testing.expectEqualStrings("", try digest(arena_state.allocator(), &.{}));
}

test "names stay inside the folder" {
    try std.testing.expect(validName("a_widget.lua"));
    for ([_][]const u8{ "../x.lua", "a/b.lua", "a\\b.lua", "x.txt", ".lua", "...lua", "" }) |bad| try std.testing.expect(!validName(bad));
}
