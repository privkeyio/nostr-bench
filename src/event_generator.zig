const std = @import("std");
const nostr = @import("nostr.zig");

/// Generate synthetic Nostr events for benchmarking
pub fn generateEvents(
    allocator: std.mem.Allocator,
    keypair: *const nostr.Keypair,
    count: u32,
) ![]nostr.Event {
    std.debug.print("Generating {d} synthetic events...\n", .{count});

    const events = try allocator.alloc(nostr.Event, count);
    errdefer allocator.free(events);

    const base_time = std.time.timestamp();

    // Minimum content size for realistic events
    const min_content_size: usize = 300;
    const base_content = "This is a benchmark test event with realistic content size. ";

    // Create padding for minimum size
    var padding: [256]u8 = undefined;
    for (&padding, 0..) |*byte, i| {
        byte.* = ' ' + @as(u8, @intCast(i % 94));
    }

    for (events, 0..) |*event, i| {
        event.* = nostr.Event{
            .id = [_]u8{0} ** 32,
            .pubkey = [_]u8{0} ** 32,
            .created_at = base_time + @as(i64, @intCast(i)),
            .kind = 1, // Text note
            .tags = &[_][]const []const u8{}, // Empty tags for simplicity
            .content = undefined,
            .sig = [_]u8{0} ** 64,
            .allocator = allocator,
        };

        // Generate content with unique identifier
        var content_buf: [512]u8 = undefined;
        const content_len = std.fmt.bufPrint(&content_buf, "{s}Event #{d}. {s}", .{
            base_content,
            i,
            padding[0..@min(padding.len, min_content_size - base_content.len - 20)],
        }) catch unreachable;

        event.content = try allocator.dupe(u8, content_len);

        // Sign the event
        try nostr.signEvent(event, keypair);

        if ((i + 1) % 1000 == 0) {
            std.debug.print("  Generated {d}/{d} events...\n", .{ i + 1, count });
        }
    }

    std.debug.print("Generated {d} events (avg ~{d} bytes content)\n", .{ count, min_content_size });

    return events;
}

/// Generate events with log-distributed sizes (more realistic)
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

        // Log-distributed size (power law)
        const uniform = random.float(f64);
        const skewed = std.math.pow(f64, uniform, 4.0);
        const max_size: usize = 100 * 1024; // 100KB max
        var content_size = @as(usize, @intFromFloat(skewed * @as(f64, @floatFromInt(max_size))));
        content_size = @max(content_size, 10); // Minimum 10 bytes

        // Generate random content
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

/// Generate events that reference each other (for testing graph queries)
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
        // Generate follow events (kind 3)
        var j: u32 = 0;
        while (j < follows_per_user) : (j += 1) {
            // Pick a random user to follow (not self)
            var target_idx = random.intRangeAtMost(usize, 0, num_users - 1);
            if (target_idx == user_idx and num_users > 1) {
                target_idx = (target_idx + 1) % num_users;
            }

            events[event_idx] = nostr.Event{
                .id = [_]u8{0} ** 32,
                .pubkey = [_]u8{0} ** 32,
                .created_at = base_time + @as(i64, @intCast(event_idx)),
                .kind = 3, // Contact list
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
