const std = @import("std");

/// This is NOT thread safe!

/// This struct is stored in Options.MemoryOptions.user_data,
/// is used to keep the allocator for the current "load of the model"
/// and the size of each allocation using a hashmap since cgltf expect a c pointer
/// but alloc and free use zig behind the c functions signatures
/// and so they alloc and free using a []T (fat pointer/slice)
const AllocTracker = struct {
    allocator: std.mem.Allocator,
    hashmap: std.AutoHashMap(usize, usize),

    fn init(allocator: std.mem.Allocator) AllocTracker {
        return .{
            .allocator = allocator,
            .hashmap = std.AutoHashMap(usize, usize).init(allocator),
        };
    }

    fn deinit(self: *@This()) void {
        self.hashmap.deinit();
    }
};

pub fn alloc(user: ?*anyopaque, size: usize) callconv(.c) ?*anyopaque {
    const tracker: *AllocTracker = @ptrCast(user);

    const bytes = tracker.allocator.alloc(u8, size) catch return null;

    const c_ptr = @intFromPtr(bytes.ptr);
    tracker.hashmap.put(c_ptr, bytes.len) catch {
        tracker.allocator.free(bytes);
        return null;
    };

    return @ptrCast(bytes.ptr);
}

pub fn free(user: ?*anyopaque, ptr: ?*anyopaque) callconv(.c) void {
    const tracker: *AllocTracker = @ptrCast(user);

    const real_ptr = ptr orelse return;
    const bytes_ptr: [*]u8 = @ptrCast(real_ptr);

    const key_value_pair = tracker.hashmap.fetchRemove(@intFromPtr(bytes_ptr)) orelse return;
    const bytes_len = key_value_pair.value;

    const bytes: []u8 = bytes_ptr[0..bytes_len];
    tracker.allocator.free(bytes);
}

pub const Result = enum(c_int) {
    success,
    data_too_short,
    unknown_format,
    invalid_json,
    invalid_gltf,
    invalid_options,
    file_not_found,
    io_error,
    out_of_memory,
    legacy_gltf,
};

pub const FileType = enum(c_int) {
    invalid,
    gltf,
    glb,
};

pub const MemoryOptions = extern struct {
    alloc: ?*const fn (user: ?*anyopaque, size: usize) callconv(.c) ?*anyopaque = null,
    free:  ?*const fn (user: ?*anyopaque, ptr: ?*anyopaque) callconv(.c) void = null,
    user_data: ?*anyopaque = null,
};

pub const FileOptions = extern struct {
    const readFnType = fn (
        memory_options: *const MemoryOptions,
        file_options: *const FileOptions,
        path: [*:0]const u8,
        size: *usize,
        data: **anyopaque
    ) callconv(.c) Result;

    const releaseFnType = fn (
        memory_options: *const MemoryOptions,
        file_options: *const FileOptions,
        data: *anyopaque,
        size: usize
    ) callconv(.c) void;

    read: ?*const readFnType = null,
    release: ?*const releaseFnType = null,
    user_data: ?*anyopaque = null,
};

pub const Options = extern struct {
    type: FileType = .invalid,   // invalid -> auto detect
    json_token_count: usize = 0, // 0 -> auto
    memory: MemoryOptions = .{},
    file: FileOptions = .{},
};
