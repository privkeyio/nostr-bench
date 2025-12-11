const std = @import("std");

/// Statistics tracking for benchmark latencies
pub const Stats = struct {
    allocator: std.mem.Allocator,
    latencies: std.ArrayListUnmanaged(i64), // nanoseconds
    total_count: u64 = 0,
    success_count: u64 = 0,
    error_count: u64 = 0,
    rate_limited_count: u64 = 0,
    start_time: i64 = 0,
    end_time: i64 = 0,

    pub fn init(allocator: std.mem.Allocator) Stats {
        return .{
            .allocator = allocator,
            .latencies = .{},
        };
    }

    pub fn deinit(self: *Stats) void {
        self.latencies.deinit(self.allocator);
    }

    pub fn reset(self: *Stats) void {
        self.latencies.clearRetainingCapacity();
        self.total_count = 0;
        self.success_count = 0;
        self.error_count = 0;
        self.rate_limited_count = 0;
        self.start_time = 0;
        self.end_time = 0;
    }

    pub fn recordStart(self: *Stats) void {
        if (self.start_time == 0) {
            self.start_time = @intCast(std.time.nanoTimestamp());
        }
    }

    pub fn recordEnd(self: *Stats) void {
        self.end_time = @intCast(std.time.nanoTimestamp());
    }

    pub fn recordSuccess(self: *Stats, latency_ns: i64) !void {
        try self.latencies.append(self.allocator, latency_ns);
        self.total_count += 1;
        self.success_count += 1;
    }

    pub fn recordRateLimited(self: *Stats, latency_ns: i64) !void {
        try self.latencies.append(self.allocator, latency_ns);
        self.total_count += 1;
        self.rate_limited_count += 1;
    }

    pub fn recordError(self: *Stats) void {
        self.total_count += 1;
        self.error_count += 1;
    }

    pub fn durationNs(self: *const Stats) i64 {
        if (self.end_time == 0 or self.start_time == 0) return 0;
        return self.end_time - self.start_time;
    }

    pub fn durationSecs(self: *const Stats) f64 {
        return @as(f64, @floatFromInt(self.durationNs())) / 1_000_000_000.0;
    }

    pub fn eventsPerSecond(self: *const Stats) f64 {
        const duration = self.durationSecs();
        if (duration <= 0) return 0;
        return @as(f64, @floatFromInt(self.success_count)) / duration;
    }

    pub fn successRate(self: *const Stats) f64 {
        if (self.total_count == 0) return 0;
        return @as(f64, @floatFromInt(self.success_count)) / @as(f64, @floatFromInt(self.total_count)) * 100.0;
    }

    /// Calculate average latency in nanoseconds
    pub fn avgLatencyNs(self: *const Stats) i64 {
        if (self.latencies.items.len == 0) return 0;
        var sum: i128 = 0;
        for (self.latencies.items) |lat| {
            sum += lat;
        }
        return @intCast(@divTrunc(sum, @as(i128, @intCast(self.latencies.items.len))));
    }

    /// Calculate percentile latency (0.0 to 1.0)
    pub fn percentileLatencyNs(self: *Stats, percentile: f64) i64 {
        if (self.latencies.items.len == 0) return 0;

        // Sort latencies for percentile calculation
        std.mem.sort(i64, self.latencies.items, {}, std.sort.asc(i64));

        const idx = @min(
            @as(usize, @intFromFloat(@as(f64, @floatFromInt(self.latencies.items.len)) * percentile)),
            self.latencies.items.len - 1,
        );
        return self.latencies.items[idx];
    }

    /// Calculate average of top 10% (slowest) latencies
    pub fn top10AvgLatencyNs(self: *Stats) i64 {
        if (self.latencies.items.len == 0) return 0;

        // Sort latencies
        std.mem.sort(i64, self.latencies.items, {}, std.sort.asc(i64));

        const start_idx = @as(usize, @intFromFloat(@as(f64, @floatFromInt(self.latencies.items.len)) * 0.9));
        const top_10 = self.latencies.items[start_idx..];

        if (top_10.len == 0) return 0;

        var sum: i128 = 0;
        for (top_10) |lat| {
            sum += lat;
        }
        return @intCast(@divTrunc(sum, @as(i128, @intCast(top_10.len))));
    }

};

pub fn formatDurationStr(ns: i64, buf: []u8) []const u8 {
    if (ns < 0) {
        return "0ns";
    }

    const abs_ns: u64 = @intCast(ns);

    if (abs_ns < 1_000) {
        return std.fmt.bufPrint(buf, "{d}ns", .{abs_ns}) catch "?";
    } else if (abs_ns < 1_000_000) {
        const us = @as(f64, @floatFromInt(abs_ns)) / 1_000.0;
        return std.fmt.bufPrint(buf, "{d:.2}us", .{us}) catch "?";
    } else if (abs_ns < 1_000_000_000) {
        const ms = @as(f64, @floatFromInt(abs_ns)) / 1_000_000.0;
        return std.fmt.bufPrint(buf, "{d:.2}ms", .{ms}) catch "?";
    } else {
        const s = @as(f64, @floatFromInt(abs_ns)) / 1_000_000_000.0;
        return std.fmt.bufPrint(buf, "{d:.2}s", .{s}) catch "?";
    }
}

/// Result of a benchmark test
pub const BenchmarkResult = struct {
    test_name: []const u8,
    duration_ns: i64,
    total_events: u64,
    events_per_second: f64,
    success_rate: f64,
    avg_latency_ns: i64,
    p50_latency_ns: i64,
    p90_latency_ns: i64,
    p95_latency_ns: i64,
    p99_latency_ns: i64,
    top10_avg_latency_ns: i64,
    workers: u32,
    errors: u64,
    rate_limited: u64,

    pub fn fromStats(stats: *Stats, test_name: []const u8, workers: u32) BenchmarkResult {
        return .{
            .test_name = test_name,
            .duration_ns = stats.durationNs(),
            .total_events = stats.success_count,
            .events_per_second = stats.eventsPerSecond(),
            .success_rate = stats.successRate(),
            .avg_latency_ns = stats.avgLatencyNs(),
            .p50_latency_ns = stats.percentileLatencyNs(0.50),
            .p90_latency_ns = stats.percentileLatencyNs(0.90),
            .p95_latency_ns = stats.percentileLatencyNs(0.95),
            .p99_latency_ns = stats.percentileLatencyNs(0.99),
            .top10_avg_latency_ns = stats.top10AvgLatencyNs(),
            .workers = workers,
            .errors = stats.error_count,
            .rate_limited = stats.rate_limited_count,
        };
    }

    pub fn print(self: *const BenchmarkResult) void {
        var buf: [7][32]u8 = undefined;
        std.debug.print("\n=== {s} ===\n", .{self.test_name});
        std.debug.print("Duration: {s}\n", .{formatDurationStr(self.duration_ns, &buf[0])});
        std.debug.print("Total Events: {d}\n", .{self.total_events});
        std.debug.print("Events/sec: {d:.2}\n", .{self.events_per_second});
        std.debug.print("Success Rate: {d:.1}%\n", .{self.success_rate});
        std.debug.print("Workers: {d}\n", .{self.workers});
        std.debug.print("Errors: {d}\n", .{self.errors});
        if (self.rate_limited > 0) {
            std.debug.print("Rate Limited: {d}\n", .{self.rate_limited});
        }
        std.debug.print("\n", .{});
        std.debug.print("Latency Statistics:\n", .{});
        std.debug.print("  Avg: {s}\n", .{formatDurationStr(self.avg_latency_ns, &buf[1])});
        std.debug.print("  P50: {s}\n", .{formatDurationStr(self.p50_latency_ns, &buf[2])});
        std.debug.print("  P90: {s}\n", .{formatDurationStr(self.p90_latency_ns, &buf[3])});
        std.debug.print("  P95: {s}\n", .{formatDurationStr(self.p95_latency_ns, &buf[4])});
        std.debug.print("  P99: {s}\n", .{formatDurationStr(self.p99_latency_ns, &buf[5])});
        std.debug.print("  Top 10% Avg: {s}\n", .{formatDurationStr(self.top10_avg_latency_ns, &buf[6])});
    }
};

/// Rate limiter using token bucket algorithm
pub const RateLimiter = struct {
    interval_ns: i64,
    last_event_ns: i64,
    mu: std.Thread.Mutex,

    pub fn init(events_per_second: u32) RateLimiter {
        const interval = @divTrunc(@as(i64, 1_000_000_000), @as(i64, @intCast(events_per_second)));
        return .{
            .interval_ns = interval,
            .last_event_ns = @intCast(std.time.nanoTimestamp()),
            .mu = .{},
        };
    }

    pub fn wait(self: *RateLimiter) void {
        self.mu.lock();
        defer self.mu.unlock();

        const now: i64 = @intCast(std.time.nanoTimestamp());
        const next_allowed = self.last_event_ns + self.interval_ns;

        if (now < next_allowed) {
            const sleep_ns: u64 = @intCast(next_allowed - now);
            std.Thread.sleep(sleep_ns);
            self.last_event_ns = next_allowed;
        } else {
            self.last_event_ns = now;
        }
    }
};

test "stats basic" {
    var stats = Stats.init(std.testing.allocator);
    defer stats.deinit();

    stats.recordStart();
    try stats.recordSuccess(1000);
    try stats.recordSuccess(2000);
    try stats.recordSuccess(3000);
    stats.recordEnd();

    try std.testing.expectEqual(@as(u64, 3), stats.success_count);
    try std.testing.expectEqual(@as(i64, 2000), stats.avgLatencyNs());
}

test "duration format" {
    var buf: [64]u8 = undefined;

    const ns = formatDurationStr(500, &buf);
    try std.testing.expectEqualStrings("500ns", ns);

    const us = formatDurationStr(5000, &buf);
    try std.testing.expect(us.len > 0);

    const ms = formatDurationStr(5_000_000, &buf);
    try std.testing.expect(ms.len > 0);
}
