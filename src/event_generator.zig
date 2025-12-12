const std = @import("std");
const nostr = @import("nostr.zig");

pub fn generateEvents(
    allocator: std.mem.Allocator,
    keypair: *const nostr.Keypair,
    count: u32,
) ![]nostr.Event {
    _ = keypair;
    std.debug.print("Generating {d} synthetic events...\n", .{count});

    const events = try allocator.alloc(nostr.Event, count);
    errdefer allocator.free(events);

    const base_time = std.time.timestamp();

    const min_content_size: usize = 300;
    const base_content = "This is a benchmark test event with realistic content size. ";

    var padding: [256]u8 = undefined;
    for (&padding, 0..) |*byte, i| {
        byte.* = ' ' + @as(u8, @intCast(i % 94));
    }

    var prng = std.Random.DefaultPrng.init(@truncate(@as(u128, @bitCast(std.time.nanoTimestamp()))));
    const random = prng.random();

    for (events, 0..) |*event, i| {
        const event_keypair = nostr.Keypair.generate();

        event.* = nostr.Event{
            .id = [_]u8{0} ** 32,
            .pubkey = [_]u8{0} ** 32,
            .created_at = base_time - @as(i64, @intCast(count - i)),
            .kind = 1,
            .tags = &[_][]const []const u8{},
            .content = undefined,
            .sig = [_]u8{0} ** 64,
            .allocator = allocator,
        };

        var content_buf: [512]u8 = undefined;
        const rand_suffix = random.int(u64);
        const content_len = std.fmt.bufPrint(&content_buf, "{s}Event #{d}. {x}. {s}", .{
            base_content,
            i,
            rand_suffix,
            padding[0..@min(padding.len, min_content_size - base_content.len - 40)],
        }) catch unreachable;

        event.content = try allocator.dupe(u8, content_len);
        try nostr.signEvent(event, &event_keypair);

        if ((i + 1) % 1000 == 0) {
            std.debug.print("  Generated {d}/{d} events...\n", .{ i + 1, count });
        }
    }

    std.debug.print("Generated {d} events (avg ~{d} bytes content)\n", .{ count, min_content_size });

    return events;
}

pub fn generateVariableSizeEvents(
    allocator: std.mem.Allocator,
    keypair: *const nostr.Keypair,
    count: u32,
) ![]nostr.Event {
    std.debug.print("Generating {d} variable-size events...\n", .{count});

    const events = try allocator.alloc(nostr.Event, count);
    errdefer allocator.free(events);

    var prng = std.Random.DefaultPrng.init(@intCast(std.time.timestamp()));
    const random = prng.random();

    const base_time = std.time.timestamp();
    var total_size: u64 = 0;

    for (events, 0..) |*event, i| {
        event.* = nostr.Event{
            .id = [_]u8{0} ** 32,
            .pubkey = [_]u8{0} ** 32,
            .created_at = base_time + @as(i64, @intCast(i)),
            .kind = 1,
            .tags = &[_][]const []const u8{},
            .content = undefined,
            .sig = [_]u8{0} ** 64,
            .allocator = allocator,
        };

        const uniform = random.float(f64);
        const skewed = std.math.pow(f64, uniform, 4.0);
        const max_size: usize = 100 * 1024;
        var content_size = @as(usize, @intFromFloat(skewed * @as(f64, @floatFromInt(max_size))));
        content_size = @max(content_size, 10);

        const content = try allocator.alloc(u8, content_size);
        for (content) |*byte| {
            byte.* = @as(u8, @intCast(random.intRangeAtMost(u8, 32, 126)));
        }
        event.content = content;
        total_size += content_size;

        try nostr.signEvent(event, keypair);

        if ((i + 1) % 1000 == 0) {
            std.debug.print("  Generated {d}/{d} events...\n", .{ i + 1, count });
        }
    }

    const avg_size = total_size / count;
    std.debug.print("Generated {d} events (avg {d} bytes content)\n", .{ count, avg_size });

    return events;
}

pub fn generateGraphEvents(
    allocator: std.mem.Allocator,
    keypairs: []const nostr.Keypair,
    follows_per_user: u32,
) ![]nostr.Event {
    const num_users = keypairs.len;
    const total_events = num_users * follows_per_user;

    std.debug.print("Generating {d} follow events ({d} users, {d} follows each)...\n", .{
        total_events,
        num_users,
        follows_per_user,
    });

    const events = try allocator.alloc(nostr.Event, total_events);
    errdefer allocator.free(events);

    var prng = std.Random.DefaultPrng.init(@intCast(std.time.timestamp()));
    const random = prng.random();

    const base_time = std.time.timestamp();
    var event_idx: usize = 0;

    for (keypairs, 0..) |*kp, user_idx| {
        var j: u32 = 0;
        while (j < follows_per_user) : (j += 1) {
            var target_idx = random.intRangeAtMost(usize, 0, num_users - 1);
            if (target_idx == user_idx and num_users > 1) {
                target_idx = (target_idx + 1) % num_users;
            }

            events[event_idx] = nostr.Event{
                .id = [_]u8{0} ** 32,
                .pubkey = [_]u8{0} ** 32,
                .created_at = base_time + @as(i64, @intCast(event_idx)),
                .kind = 3,
                .tags = &[_][]const []const u8{},
                .content = "",
                .sig = [_]u8{0} ** 64,
                .allocator = allocator,
            };

            try nostr.signEvent(&events[event_idx], kp);
            event_idx += 1;
        }

        if ((user_idx + 1) % 100 == 0) {
            std.debug.print("  Generated events for {d}/{d} users...\n", .{ user_idx + 1, num_users });
        }
    }

    std.debug.print("Generated {d} follow events\n", .{total_events});

    return events;
}

test "generate events" {
    const allocator = std.testing.allocator;
    const keypair = nostr.Keypair.generate();

    const events = try generateEvents(allocator, &keypair, 10);
    defer {
        for (events) |*ev| {
            if (ev.allocator) |alloc| {
                alloc.free(ev.content);
            }
        }
        allocator.free(events);
    }

    try std.testing.expectEqual(@as(usize, 10), events.len);
}
