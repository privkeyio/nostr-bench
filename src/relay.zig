const std = @import("std");

pub const RelayInstance = struct {
    url: []const u8,

    pub fn displayName(self: *const RelayInstance) []const u8 {
        return self.url;
    }
};

pub const RelayManager = struct {
    allocator: std.mem.Allocator,
    instances: std.ArrayListUnmanaged(RelayInstance),

    pub fn init(allocator: std.mem.Allocator) RelayManager {
        return .{
            .allocator = allocator,
            .instances = .{},
        };
    }

    pub fn deinit(self: *RelayManager) void {
        self.instances.deinit(self.allocator);
    }

    pub fn addRelay(self: *RelayManager, url: []const u8) !void {
        try self.instances.append(self.allocator, .{
            .url = url,
        });
    }

    pub fn getRelays(self: *RelayManager) []RelayInstance {
        return self.instances.items;
    }
};
