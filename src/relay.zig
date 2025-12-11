const std = @import("std");

pub const RelayKind = enum {
    orly,
    wisp,

    pub fn name(self: RelayKind) []const u8 {
        return switch (self) {
            .orly => "orly",
            .wisp => "wisp",
        };
    }

    pub fn displayName(self: RelayKind) []const u8 {
        return switch (self) {
            .orly => "Orly (next.orly.dev)",
            .wisp => "Wisp",
        };
    }

    pub fn defaultPort(self: RelayKind) u16 {
        return switch (self) {
            .orly => 3334,
            .wisp => 7777,
        };
    }

    pub fn fromString(s: []const u8) ?RelayKind {
        if (std.mem.eql(u8, s, "orly")) return .orly;
        if (std.mem.eql(u8, s, "wisp")) return .wisp;
        return null;
    }
};

pub const RelayInstance = struct {
    kind: RelayKind,
    url: []const u8,
    process: ?std.process.Child = null,
    managed: bool = false,

    pub fn getUrl(self: *const RelayInstance) []const u8 {
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
        for (self.instances.items) |*instance| {
            if (instance.managed) {
                self.stopRelay(instance);
            }
        }
        self.instances.deinit(self.allocator);
    }

    pub fn addRelay(self: *RelayManager, kind: RelayKind, url: ?[]const u8) !*RelayInstance {
        const relay_url = url orelse blk: {
            var buf: [64]u8 = undefined;
            const default_url = std.fmt.bufPrint(&buf, "ws://127.0.0.1:{d}", .{kind.defaultPort()}) catch unreachable;
            break :blk try self.allocator.dupe(u8, default_url);
        };

        try self.instances.append(self.allocator, .{
            .kind = kind,
            .url = relay_url,
            .managed = url == null,
        });

        return &self.instances.items[self.instances.items.len - 1];
    }

    pub fn addRelayUrl(self: *RelayManager, url: []const u8) !*RelayInstance {
        try self.instances.append(self.allocator, .{
            .kind = .orly,
            .url = url,
            .managed = false,
        });
        return &self.instances.items[self.instances.items.len - 1];
    }

    fn stopRelay(self: *RelayManager, instance: *RelayInstance) void {
        _ = self;
        if (instance.process) |*proc| {
            _ = proc.kill() catch {};
        }
        instance.process = null;
    }

    pub fn getRelays(self: *RelayManager) []RelayInstance {
        return self.instances.items;
    }
};

pub const all_relay_kinds = [_]RelayKind{ .orly, .wisp };

pub fn parseRelayList(allocator: std.mem.Allocator, arg: []const u8) ![]RelayKind {
    var list = std.ArrayListUnmanaged(RelayKind){};
    var iter = std.mem.splitScalar(u8, arg, ',');
    while (iter.next()) |name| {
        const trimmed = std.mem.trim(u8, name, " ");
        if (RelayKind.fromString(trimmed)) |kind| {
            try list.append(allocator, kind);
        }
    }
    return list.toOwnedSlice(allocator);
}
