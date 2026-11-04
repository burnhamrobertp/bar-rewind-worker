//! Installing the worker to run unattended: a copy of it in its own folder, started at logon by a
//! scheduled task on Windows, or kept running by a systemd user unit on Linux. Neither needs admin rights.

const std = @import("std");
const builtin = @import("builtin");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const windows = builtin.os.tag == .windows;
const exe_suffix = if (windows) ".exe" else "";

pub const task_name = "BAR Rewind worker";
const unit_name = "bar-rewind-worker.service";

/// Where an installed worker lives: it replaces itself there on updates, so a download can go anywhere
pub fn installedExe(arena: Allocator, home: []const u8) ![]const u8 {
    return std.fs.path.join(arena, &.{ home, "bin", "bar-rewind-worker" ++ exe_suffix });
}

/// Copies the running worker into place, and registers and starts it with `args`. One already installed
/// stops first: Windows won't overwrite a running program, and neither systemd nor the task would restart
/// it on their own.
pub fn install(arena: Allocator, io: Io, env: *std.process.Environ.Map, home: []const u8, args: []const []const u8, task: []const u8) ![]const u8 {
    const exe = try installedExe(arena, home);
    if (windows) {
        _ = run(arena, io, &.{ "schtasks", "/End", "/TN", task }) catch {};
    } else _ = run(arena, io, &.{ "systemctl", "--user", "stop", unit_name }) catch {};
    const self = try std.process.executablePathAlloc(io, arena);
    if (!std.mem.eql(u8, self, exe)) {
        try Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(exe).?);
        try Io.Dir.cwd().copyFile(self, Io.Dir.cwd(), exe, io, .{});
    }
    if (windows) try installTask(arena, io, env, home, exe, args, task) else try installUnit(arena, io, env, exe, args);

    return exe;
}

pub fn uninstall(arena: Allocator, io: Io, env: *std.process.Environ.Map, task: []const u8) !void {
    if (windows) {
        _ = run(arena, io, &.{ "schtasks", "/End", "/TN", task }) catch {};
        if (!try run(arena, io, &.{ "schtasks", "/Delete", "/TN", task, "/F" })) return error.TaskNotRemoved;

        return;
    }
    _ = try run(arena, io, &.{ "systemctl", "--user", "disable", "--now", unit_name });
    Io.Dir.cwd().deleteFile(io, try unitPath(arena, env)) catch {};
    _ = try run(arena, io, &.{ "systemctl", "--user", "daemon-reload" });
}

fn run(arena: Allocator, io: Io, argv: []const []const u8) !bool {
    const result = try std.process.run(arena, io, .{ .argv = argv, .create_no_window = true });
    if (result.term == .exited and result.term.exited == 0) return true;
    std.log.warn("{s} said: {s}{s}", .{ argv[0], std.mem.trim(u8, result.stdout, " \r\n"), std.mem.trim(u8, result.stderr, " \r\n") });

    return false;
}

fn xmlEscape(w: *Io.Writer, text: []const u8) !void {
    for (text) |c| switch (c) {
        '&' => try w.writeAll("&amp;"),
        '<' => try w.writeAll("&lt;"),
        '>' => try w.writeAll("&gt;"),
        '"' => try w.writeAll("&quot;"),
        else => try w.writeByte(c),
    };
}

/// A Windows command line: each argument quoted, so a path with spaces stays one argument
fn commandLine(w: *Io.Writer, args: []const []const u8) !void {
    for (args, 0..) |a, i| {
        if (i > 0) try w.writeByte(' ');
        try w.writeByte('"');
        try w.writeAll(a);
        try w.writeByte('"');
    }
}

/// At this user's logon, kept running with no time limit
pub fn taskXml(arena: Allocator, w: *Io.Writer, user: []const u8, exe: []const u8, args: []const []const u8) !void {
    try w.writeAll(
        \\<?xml version="1.0" encoding="UTF-16"?>
        \\<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
        \\  <RegistrationInfo><Description>Parses BAR replays for a BAR Rewind server</Description></RegistrationInfo>
        \\  <Triggers><LogonTrigger><Enabled>true</Enabled><UserId>
    );
    try xmlEscape(w, user);
    try w.writeAll(
        \\</UserId></LogonTrigger></Triggers>
        \\  <Principals><Principal id="Author"><UserId>
    );
    try xmlEscape(w, user);
    try w.writeAll(
        \\</UserId><LogonType>InteractiveToken</LogonType><RunLevel>LeastPrivilege</RunLevel></Principal></Principals>
        \\  <Settings>
        \\    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
        \\    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
        \\    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
        \\    <ExecutionTimeLimit>PT0S</ExecutionTimeLimit>
        \\    <RestartOnFailure><Interval>PT1M</Interval><Count>999</Count></RestartOnFailure>
        \\    <Priority>7</Priority>
        \\  </Settings>
        \\  <Actions Context="Author"><Exec><Command>
    );
    try xmlEscape(w, exe);
    try w.writeAll("</Command><Arguments>");
    var line: Io.Writer.Allocating = .init(arena);
    try commandLine(&line.writer, args);
    try xmlEscape(w, line.written());
    try w.writeAll("</Arguments></Exec></Actions>\n</Task>\n");
}

fn installTask(arena: Allocator, io: Io, env: *std.process.Environ.Map, home: []const u8, exe: []const u8, args: []const []const u8, task: []const u8) !void {
    const user = try std.fmt.allocPrint(arena, "{s}\\{s}", .{ env.get("USERDOMAIN") orelse ".", env.get("USERNAME") orelse return error.NoUserName });
    var xml: Io.Writer.Allocating = .init(arena);
    try taskXml(arena, &xml.writer, user, exe, args);
    // schtasks reads a task definition as UTF-16, as its header says
    const wide = try std.unicode.wtf8ToWtf16LeAlloc(arena, xml.written());
    var bytes: std.ArrayList(u8) = .empty;
    try bytes.appendSlice(arena, &.{ 0xFF, 0xFE });
    try bytes.appendSlice(arena, std.mem.sliceAsBytes(wide));
    const path = try std.fs.path.join(arena, &.{ home, "task.xml" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes.items });
    defer Io.Dir.cwd().deleteFile(io, path) catch {};
    if (!try run(arena, io, &.{ "schtasks", "/Create", "/TN", task, "/XML", path, "/F" })) return error.TaskNotCreated;
    if (!try run(arena, io, &.{ "schtasks", "/Run", "/TN", task })) return error.TaskNotStarted;
}

fn unitPath(arena: Allocator, env: *std.process.Environ.Map) ![]const u8 {
    const config = env.get("XDG_CONFIG_HOME") orelse try std.fs.path.join(arena, &.{ env.get("HOME") orelse return error.NoHome, ".config" });

    return std.fs.path.join(arena, &.{ config, "systemd", "user", unit_name });
}

/// The user unit: systemd starts the supervisor again if it dies
pub fn unitText(w: *Io.Writer, exe: []const u8, args: []const []const u8) !void {
    try w.print("[Unit]\nDescription=BAR Rewind worker\nAfter=network-online.target\n\n[Service]\nExecStart=\"{s}\"", .{exe});
    for (args) |a| try w.print(" \"{s}\"", .{a});
    try w.writeAll("\nRestart=always\nRestartSec=30\nNice=10\n\n[Install]\nWantedBy=default.target\n");
}

fn installUnit(arena: Allocator, io: Io, env: *std.process.Environ.Map, exe: []const u8, args: []const []const u8) !void {
    const path = try unitPath(arena, env);
    try Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(path).?);
    var text: Io.Writer.Allocating = .init(arena);
    try unitText(&text.writer, exe, args);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = text.written() });
    if (!try run(arena, io, &.{ "systemctl", "--user", "daemon-reload" })) return error.UnitNotLoaded;
    if (!try run(arena, io, &.{ "systemctl", "--user", "enable", unit_name })) return error.UnitNotEnabled;
    if (!try run(arena, io, &.{ "systemctl", "--user", "restart", unit_name })) return error.UnitNotStarted;
}

test "the task runs the installed worker with its arguments kept whole and escaped" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var out: Io.Writer.Allocating = .init(arena.allocator());
    try taskXml(arena.allocator(), &out.writer, "PC\\mod & co", "C:\\Users\\Mod\\AppData\\Local\\bar-rewind-worker\\bin\\bar-rewind-worker.exe", &.{ "--background", "--server", "https://a.example/?x=1&y=2" });
    const xml = out.written();
    try std.testing.expect(std.mem.indexOf(u8, xml, "<UserId>PC\\mod &amp; co</UserId>") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "<Arguments>&quot;--background&quot; &quot;--server&quot; &quot;https://a.example/?x=1&amp;y=2&quot;</Arguments>") != null);
}

test "the unit runs the installed worker with its arguments quoted" {
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try unitText(&out.writer, "/home/mod/.local/share/bar-rewind-worker/bin/bar-rewind-worker", &.{ "--server", "https://a.example" });
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "ExecStart=\"/home/mod/.local/share/bar-rewind-worker/bin/bar-rewind-worker\" \"--server\" \"https://a.example\"\n") != null);
}
