const std = @import("std");
const nostr = @import("nostr");

pub const Event = nostr.EventBuilder;

pub fn freeEvents(allocator: std.mem.Allocator, events: []Event) void {
    for (events) |*ev| {
        allocator.free(ev.content_slice);
    }
    allocator.free(events);
}

pub fn generateEvents(
    allocator: std.mem.Allocator,
    keypair: *const nostr.Keypair,
    count: u32,
) ![]Event {
    _ = keypair;
    std.debug.print("Generating {d} synthetic events...\n", .{count});

    const events = try allocator.alloc(Event, count);
    errdefer allocator.free(events);

    const base_time = nostr.io.timestamp();

    const min_content_size: usize = 300;
    const base_content = "This is a benchmark test event with realistic content size. ";

    var padding: [256]u8 = undefined;
    for (&padding, 0..) |*byte, i| {
        byte.* = ' ' + @as(u8, @intCast(i % 94));
    }

    var prng = std.Random.DefaultPrng.init(@truncate(@as(u128, @bitCast(nostr.io.nanoTimestamp()))));
    const random = prng.random();

    for (events, 0..) |*event, i| {
        const event_keypair = nostr.Keypair.generate();

        var content_buf: [512]u8 = undefined;
        const rand_suffix = random.int(u64);
        const content_len = std.fmt.bufPrint(&content_buf, "{s}Event #{d}. {x}. {s}", .{
            base_content,
            i,
            rand_suffix,
            padding[0..@min(padding.len, min_content_size - base_content.len - 40)],
        }) catch unreachable;

        const content = try allocator.dupe(u8, content_len);
        errdefer allocator.free(content);

        event.* = .{};
        _ = event.setKind(1).setContent(content).setCreatedAt(base_time - @as(i64, @intCast(count - i)));
        try event.sign(&event_keypair);

        if ((i + 1) % 1000 == 0) {
            std.debug.print("  Generated {d}/{d} events...\n", .{ i + 1, count });
        }
    }

    std.debug.print("Generated {d} events (avg ~{d} bytes content)\n", .{ count, min_content_size });

    return events;
}

pub fn generateSearchableEvents(
    allocator: std.mem.Allocator,
    keypair: *const nostr.Keypair,
    count: u32,
) ![]Event {
    _ = keypair;
    std.debug.print("Generating {d} searchable events...\n", .{count});

    const events = try allocator.alloc(Event, count);
    errdefer allocator.free(events);

    const base_time = nostr.io.timestamp();

    const templates = [_][]const u8{
        "Just discovered Bitcoin and it's changing how I think about money! #bitcoin",
        "Building on Nostr is amazing - the protocol is so simple yet powerful. #nostr",
        "Lightning Network is the future of payments. Instant and nearly free! #lightning #bitcoin",
        "Reading about Satoshi Nakamoto's vision in the whitepaper again. #satoshi #bitcoin",
        "Just got my first zap on Nostr! This is incredible. #zap #nostr #lightning",
        "Bitcoin fixes the money printer problem. Sound money for everyone. #bitcoin",
        "The Nostr community is growing fast! So many great apps being built. #nostr",
        "Lightning channels are the plumbing of the future financial system. #lightning",
        "Satoshi's invention will be studied for centuries. #satoshi",
        "Sending zaps is so much fun! Instant micropayments. #zap",
        "Stacking sats and building on Nostr. The future is decentralized! #bitcoin #nostr",
        "Lightning wallet UX is getting really good. #lightning",
        "Who is Satoshi? Does it even matter anymore? #satoshi #bitcoin",
        "Zapped my favorite content creator today. Supporting creators has never been easier. #zap #nostr",
        "Bitcoin, Nostr, Lightning - the holy trinity of freedom tech. #bitcoin #nostr #lightning",
    };

    var prng = std.Random.DefaultPrng.init(@truncate(@as(u128, @bitCast(nostr.io.nanoTimestamp()))));
    const random = prng.random();

    for (events, 0..) |*event, i| {
        const event_keypair = nostr.Keypair.generate();

        const template = templates[random.intRangeAtMost(usize, 0, templates.len - 1)];
        var content_buf: [512]u8 = undefined;
        const rand_suffix = random.int(u32);
        const content_len = std.fmt.bufPrint(&content_buf, "{s} Event #{d}-{x}", .{
            template,
            i,
            rand_suffix,
        }) catch unreachable;

        const content = try allocator.dupe(u8, content_len);
        errdefer allocator.free(content);

        event.* = .{};
        _ = event.setKind(1).setContent(content).setCreatedAt(base_time - @as(i64, @intCast(count - i)));
        try event.sign(&event_keypair);

        if ((i + 1) % 500 == 0) {
            std.debug.print("  Generated {d}/{d} searchable events...\n", .{ i + 1, count });
        }
    }

    std.debug.print("Generated {d} searchable events\n", .{count});
    return events;
}

test "generate events" {
    try nostr.init();
    defer nostr.cleanup();

    const allocator = std.testing.allocator;
    const keypair = nostr.Keypair.generate();

    const events = try generateEvents(allocator, &keypair, 10);
    defer freeEvents(allocator, events);

    try std.testing.expectEqual(@as(usize, 10), events.len);
}
