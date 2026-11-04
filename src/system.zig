//! What the machine has (memory, disk, cores), and a parse's process tree.

const std = @import("std");
const builtin = @import("builtin");

const Io = std.Io;
const windows = builtin.os.tag == .windows;
const win = std.os.windows;

pub const os_name = if (windows) "windows" else @tagName(builtin.os.tag);

pub const Memory = struct { total_mb: u64, free_mb: u64 };

pub fn memory(io: Io) Memory {
    if (windows) {
        var status: MemoryStatusEx = .{};
        if (!win32.GlobalMemoryStatusEx(&status).toBool()) return .{ .total_mb = 0, .free_mb = 0 };

        return .{ .total_mb = status.total_phys >> 20, .free_mb = status.avail_phys >> 20 };
    }
    var buffer: [4096]u8 = undefined;
    const text = Io.Dir.cwd().readFile(io, "/proc/meminfo", &buffer) catch return .{ .total_mb = 0, .free_mb = 0 };

    return .{ .total_mb = meminfoKb(text, "MemTotal:") >> 10, .free_mb = meminfoKb(text, "MemAvailable:") >> 10 };
}

fn meminfoKb(text: []const u8, key: []const u8) u64 {
    const at = std.mem.indexOf(u8, text, key) orelse return 0;
    var fields = std.mem.tokenizeAny(u8, text[at + key.len ..], " \t");

    return std.fmt.parseInt(u64, fields.next() orelse return 0, 10) catch 0;
}

pub fn diskFreeMb(gpa: std.mem.Allocator, path: []const u8) u64 {
    if (windows) {
        const wide = std.unicode.wtf8ToWtf16LeAllocZ(gpa, path) catch return 0;
        var free: u64 = 0;
        if (!win32.GetDiskFreeSpaceExW(wide, &free, null, null).toBool()) return 0;

        return free >> 20;
    }
    const z = gpa.dupeSentinel(u8, path, 0) catch return 0;
    var info: LinuxStatfs = undefined;
    if (std.os.linux.syscall2(.statfs, @intFromPtr(z.ptr), @intFromPtr(&info)) != 0) return 0;

    return (info.bavail * info.bsize) >> 20;
}

pub fn cpus() u32 {
    return @intCast(std.Thread.getCpuCount() catch 1);
}

/// Parses run below normal priority, so the machine's owner barely notices them
pub fn lowerPriority() void {
    if (!windows) _ = std.os.linux.syscall3(.setpriority, 0, 0, 10);
}

/// Every process a parse starts. On Windows they share a Job Object, which also kills them all when the
/// worker exits however it exits; on Linux they share a process group, and the worker samples their
/// peak memory from /proc.
pub const Tree = struct {
    root: std.process.Child.Id,
    job: if (windows) ?win.HANDLE else void,
    peak_kb: u64 = 0,

    pub fn watch(child: *const std.process.Child) Tree {
        var tree: Tree = .{ .root = child.id.?, .job = if (windows) null else {} };
        if (windows) {
            const job = win32.CreateJobObjectW(null, null) orelse return tree;
            var limits: ExtendedLimits = .{};
            limits.basic.limit_flags = job_kill_on_close | job_priority_class;
            limits.basic.priority_class = below_normal_priority;
            _ = win32.SetInformationJobObject(job, job_extended_limits, &limits, @sizeOf(ExtendedLimits));
            if (win32.AssignProcessToJobObject(job, child.id.?).toBool()) tree.job = job;
        }

        return tree;
    }

    /// The highest memory any one process in the tree has used so far
    pub fn peakMb(tree: *Tree, io: Io, gpa: std.mem.Allocator) u64 {
        if (windows) {
            const job = tree.job orelse return 0;
            var limits: ExtendedLimits = .{};
            if (!win32.QueryInformationJobObject(job, job_extended_limits, &limits, @sizeOf(ExtendedLimits), null).toBool()) return tree.peak_kb >> 10;

            return limits.peak_process_memory_used >> 20;
        }
        sampleLinux(tree, io, gpa) catch {};

        return tree.peak_kb >> 10;
    }

    pub fn terminate(tree: *Tree) void {
        if (windows) {
            if (tree.job) |job| _ = win32.TerminateJobObject(job, 1);
        } else _ = std.os.linux.kill(-tree.root, std.os.linux.SIG.KILL);
    }

    pub fn close(tree: *Tree) void {
        if (windows) if (tree.job) |job| win.CloseHandle(job);
    }
};

fn sampleLinux(tree: *Tree, io: Io, gpa: std.mem.Allocator) !void {
    var parents: std.AutoHashMapUnmanaged(std.posix.pid_t, std.posix.pid_t) = .empty;
    defer parents.deinit(gpa);
    var proc = try Io.Dir.cwd().openDir(io, "/proc", .{ .iterate = true });
    defer proc.close(io);
    var it = proc.iterate();
    var buffer: [512]u8 = undefined;
    while (try it.next(io)) |entry| {
        const pid = std.fmt.parseInt(std.posix.pid_t, entry.name, 10) catch continue;
        var path: [64]u8 = undefined;
        const stat = proc.readFile(io, std.fmt.bufPrint(&path, "{d}/stat", .{pid}) catch continue, &buffer) catch continue;
        // pid (name) state ppid ...: the name can hold spaces and parentheses, so read after its last ')'
        const close_paren = std.mem.lastIndexOfScalar(u8, stat, ')') orelse continue;
        var fields = std.mem.tokenizeScalar(u8, stat[close_paren + 1 ..], ' ');
        _ = fields.next();
        const ppid = std.fmt.parseInt(std.posix.pid_t, fields.next() orelse continue, 10) catch continue;
        try parents.put(gpa, pid, ppid);
    }
    var keys = parents.keyIterator();
    while (keys.next()) |pid| {
        var p = pid.*;
        const inside = while (true) {
            if (p == tree.root) break true;
            p = parents.get(p) orelse break false;
            if (p <= 1) break false;
        };
        if (!inside) continue;
        var path: [64]u8 = undefined;
        const status = proc.readFile(io, std.fmt.bufPrint(&path, "{d}/status", .{pid.*}) catch continue, &buffer) catch continue;
        tree.peak_kb = @max(tree.peak_kb, meminfoKb(status, "VmHWM:"));
    }
}

test "meminfo and status fields" {
    try std.testing.expectEqual(16314880, meminfoKb("MemTotal:       16314880 kB\nMemFree:  1 kB\n", "MemTotal:"));
    try std.testing.expectEqual(0, meminfoKb("MemFree: 1 kB\n", "MemAvailable:"));
    try std.testing.expectEqual(904, meminfoKb("Name:\tspring\nVmHWM:\t     904 kB\n", "VmHWM:"));
}

// Windows ----------------------------------------------------------------------------------------------

const MemoryStatusEx = extern struct {
    length: u32 = @sizeOf(MemoryStatusEx),
    memory_load: u32 = 0,
    total_phys: u64 = 0,
    avail_phys: u64 = 0,
    total_page_file: u64 = 0,
    avail_page_file: u64 = 0,
    total_virtual: u64 = 0,
    avail_virtual: u64 = 0,
    avail_extended_virtual: u64 = 0,
};

const BasicLimits = extern struct {
    per_process_user_time_limit: i64 = 0,
    per_job_user_time_limit: i64 = 0,
    limit_flags: u32 = 0,
    minimum_working_set_size: usize = 0,
    maximum_working_set_size: usize = 0,
    active_process_limit: u32 = 0,
    affinity: usize = 0,
    priority_class: u32 = 0,
    scheduling_class: u32 = 0,
};

const ExtendedLimits = extern struct {
    basic: BasicLimits = .{},
    io_counters: [6]u64 = @splat(0),
    process_memory_limit: usize = 0,
    job_memory_limit: usize = 0,
    peak_process_memory_used: usize = 0,
    peak_job_memory_used: usize = 0,
};

const job_extended_limits = 9;
const job_kill_on_close = 0x2000;
const job_priority_class = 0x20;
const below_normal_priority = 0x4000;

const win32 = if (windows) struct {
    extern "kernel32" fn GlobalMemoryStatusEx(status: *MemoryStatusEx) callconv(.winapi) win.BOOL;
    extern "kernel32" fn GetDiskFreeSpaceExW(dir: [*:0]const u16, free_to_caller: ?*u64, total: ?*u64, total_free: ?*u64) callconv(.winapi) win.BOOL;
    extern "kernel32" fn CreateJobObjectW(attributes: ?*anyopaque, name: ?[*:0]const u16) callconv(.winapi) ?win.HANDLE;
    extern "kernel32" fn SetInformationJobObject(job: win.HANDLE, class: c_int, info: *anyopaque, length: u32) callconv(.winapi) win.BOOL;
    extern "kernel32" fn AssignProcessToJobObject(job: win.HANDLE, process: win.HANDLE) callconv(.winapi) win.BOOL;
    extern "kernel32" fn TerminateJobObject(job: win.HANDLE, exit_code: u32) callconv(.winapi) win.BOOL;
    extern "kernel32" fn QueryInformationJobObject(job: win.HANDLE, class: c_int, info: *anyopaque, length: u32, returned: ?*u32) callconv(.winapi) win.BOOL;
} else struct {};

// Linux ------------------------------------------------------------------------------------------------

const LinuxStatfs = extern struct {
    type: isize,
    bsize: u64,
    blocks: u64,
    bfree: u64,
    bavail: u64,
    files: u64,
    ffree: u64,
    fsid: [2]i32,
    namelen: isize,
    frsize: isize,
    flags: isize,
    spare: [4]isize,
};
