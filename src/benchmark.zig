const std = @import("std");
const nostr = @import("nostr");
const stats_mod = @import("stats.zig");
const event_gen = @import("event_generator.zig");

const ws = nostr.ws;
const Config = @import("main.zig").Config;
const Stats = stats_mod.Stats;
const BenchmarkResult = stats_mod.BenchmarkResult;
const RateLimiter = stats_mod.RateLimiter;
const Event = event_gen.Event;

/// Thin benchmark-side wrapper over libnostr-z's ws.Client that speaks the
/// Nostr client protocol (EVENT/REQ/CLOSE) and parses relay replies.
const Conn = struct {
    client: ws.Client,
    allocator: std.mem.Allocator,
    send_buf: [65536]u8 = undefined,

    fn connect(allocator: std.mem.Allocator, url: []const u8) !Conn {
        return .{
            .client = try ws.Client.connect(allocator, url),
            .allocator = allocator,
        };
    }

    fn deinit(self: *Conn) void {
        self.client.close();
    }

    fn setReadTimeout(self: *Conn, timeout_ms: u32) void {
        self.client.setReadTimeout(timeout_ms);
    }

    fn sendEvent(self: *Conn, event: *const Event) !void {
        var w = std.Io.Writer.fixed(&self.send_buf);
        try w.writeAll("[\"EVENT\",");
        const event_json = try event.serialize(self.send_buf[w.end..]);
        w.end += event_json.len;
        try w.writeAll("]");
        try self.client.sendText(w.buffered());
    }

    fn sendReq(self: *Conn, sub_id: []const u8, filters: []const nostr.Filter) !void {
        const msg = try nostr.ClientMsg.reqMsg(sub_id, filters, &self.send_buf);
        try self.client.sendText(msg);
    }

    fn sendClose(self: *Conn, sub_id: []const u8) !void {
        const msg = try nostr.ClientMsg.closeMsg(sub_id, &self.send_buf);
        try self.client.sendText(msg);
    }

    /// Receives and parses the next relay message. Returns null when the
    /// connection is closed by the peer; a malformed payload parses as
    /// `.unknown` rather than erroring so read loops can skip it.
    fn receive(self: *Conn, allocator: std.mem.Allocator) !?nostr.RelayMsgParsed {
        var msg = self.client.recvMessage() catch |err| switch (err) {
            error.EndOfStream, error.ConnectionResetByPeer => return null,
            else => return error.ReceiveFailed,
        };
        defer msg.deinit();
        return nostr.RelayMsgParsed.parse(msg.payload, allocator) catch
            nostr.RelayMsgParsed{ .msg_type = .unknown };
    }

    /// Waits for the OK that acknowledges a published event, skipping unrelated
    /// messages that may sit ahead of it on the wire (a CLOSED left over from a
    /// prior CLOSE, a NOTICE, or a stray EVENT/EOSE). Returns the OK, or null if
    /// the connection closes or no OK arrives within a bounded number of reads.
    fn awaitOk(self: *Conn, allocator: std.mem.Allocator) !?nostr.RelayMsgParsed {
        var reads: u32 = 0;
        while (reads < 16) : (reads += 1) {
            const msg = (try self.receive(allocator)) orelse return null;
            if (msg.msg_type == .ok) return msg;
        }
        return null;
    }
};

pub const Benchmark = struct {
    allocator: std.mem.Allocator,
    config: Config,
    results: std.ArrayListUnmanaged(BenchmarkResult),
    keypair: nostr.Keypair,

    pub fn init(allocator: std.mem.Allocator, config: Config) !Benchmark {
        return .{
            .allocator = allocator,
            .config = config,
            .results = .empty,
            .keypair = nostr.Keypair.generate(),
        };
    }

    pub fn deinit(self: *Benchmark) void {
        self.results.deinit(self.allocator);
    }

    pub fn run(self: *Benchmark) !void {
        if (self.config.run_peak_throughput) {
            std.debug.print("\nRunning Peak Throughput Test...\n", .{});
            const result = try self.runPeakThroughputTest();
            try self.results.append(self.allocator, result);
        }

        if (self.config.run_burst_pattern) {
            std.debug.print("\nRunning Burst Pattern Test...\n", .{});
            const result = try self.runBurstPatternTest();
            try self.results.append(self.allocator, result);
        }

        if (self.config.run_mixed_rw) {
            std.debug.print("\nRunning Mixed Read/Write Test...\n", .{});
            const result = try self.runMixedReadWriteTest();
            try self.results.append(self.allocator, result);
        }

        if (self.config.run_query) {
            std.debug.print("\nRunning Query Performance Test...\n", .{});
            const result = try self.runQueryTest();
            try self.results.append(self.allocator, result);
        }

        if (self.config.run_concurrent_rw) {
            std.debug.print("\nRunning Concurrent Query/Store Test...\n", .{});
            const result = try self.runConcurrentQueryStoreTest();
            try self.results.append(self.allocator, result);
        }

        if (self.config.run_search) {
            std.debug.print("\nRunning NIP-50 Search Test...\n", .{});
            const result = try self.runSearchTest();
            try self.results.append(self.allocator, result);
        }
    }

    fn runPeakThroughputTest(self: *Benchmark) !BenchmarkResult {
        var stats = Stats.init(self.allocator);
        defer stats.deinit();

        const events = try event_gen.generateEvents(self.allocator, &self.keypair, self.config.num_events);
        defer event_gen.freeEvents(self.allocator, events);

        stats.recordStart();

        const threads = try self.allocator.alloc(std.Thread, self.config.workers);
        defer self.allocator.free(threads);

        var shared_stats = SharedStats{
            .stats = &stats,
            .mu = .init,
        };

        const events_per_worker = events.len / self.config.workers;

        for (threads, 0..) |*thread, i| {
            const start_idx = i * events_per_worker;
            const end_idx = if (i == self.config.workers - 1) events.len else start_idx + events_per_worker;
            const worker_events = events[start_idx..end_idx];

            if (self.config.async_publish) {
                thread.* = try std.Thread.spawn(.{}, asyncWorkerThread, .{
                    self.config.relay_url,
                    worker_events,
                    &shared_stats,
                    self.config.rate_per_worker,
                });
            } else {
                thread.* = try std.Thread.spawn(.{}, workerThread, .{
                    self.config.relay_url,
                    worker_events,
                    &shared_stats,
                    self.config.rate_per_worker,
                });
            }
        }

        for (threads) |thread| {
            thread.join();
        }

        stats.recordEnd();

        const name = if (self.config.async_publish) "Peak Throughput (async)" else "Peak Throughput";
        return BenchmarkResult.fromStats(&stats, name, self.config.workers);
    }

    fn runBurstPatternTest(self: *Benchmark) !BenchmarkResult {
        var stats = Stats.init(self.allocator);
        defer stats.deinit();

        const events = try event_gen.generateEvents(self.allocator, &self.keypair, self.config.num_events);
        defer event_gen.freeEvents(self.allocator, events);

        stats.recordStart();

        // Burst pattern: send events in bursts with pauses between
        const burst_size = self.config.num_events / 10;
        const quiet_period_ns: u64 = 500_000_000; // 500ms
        const burst_interval_ns: u64 = 10_000_000; // 10ms between events in burst

        var event_idx: usize = 0;
        var conn = Conn.connect(self.allocator, self.config.relay_url) catch {
            stats.recordEnd();
            return BenchmarkResult.fromStats(&stats, "Burst Pattern", self.config.workers);
        };
        defer conn.deinit();
        conn.setReadTimeout(5000);

        while (event_idx < events.len) {
            // Burst
            const burst_end = @min(event_idx + burst_size, events.len);
            while (event_idx < burst_end) : (event_idx += 1) {
                const start_ns = nostr.io.nanoTimestamp();

                conn.sendEvent(&events[event_idx]) catch {
                    stats.recordError();
                    continue;
                };

                // Wait for OK response (with timeout)
                if (conn.awaitOk(self.allocator)) |maybe_ok| {
                    if (maybe_ok) |ok| {
                        if (ok.success) {
                            const latency: i64 = @intCast(nostr.io.nanoTimestamp() - start_ns);
                            try stats.recordSuccess(latency);
                        } else {
                            stats.recordError();
                        }
                    }
                } else |_| {
                    stats.recordError();
                }

                try std.Io.sleep(nostr.io.io(), .{ .nanoseconds = @intCast(burst_interval_ns) }, .awake);
            }

            // Quiet period
            try std.Io.sleep(nostr.io.io(), .{ .nanoseconds = @intCast(quiet_period_ns) }, .awake);
        }

        stats.recordEnd();

        return BenchmarkResult.fromStats(&stats, "Burst Pattern", 1);
    }

    fn runMixedReadWriteTest(self: *Benchmark) !BenchmarkResult {
        var stats = Stats.init(self.allocator);
        defer stats.deinit();

        const num_events = self.config.num_events / 2; // Half for write
        const events = try event_gen.generateEvents(self.allocator, &self.keypair, num_events);
        defer event_gen.freeEvents(self.allocator, events);

        stats.recordStart();

        var conn = Conn.connect(self.allocator, self.config.relay_url) catch {
            stats.recordEnd();
            return BenchmarkResult.fromStats(&stats, "Mixed Read/Write", self.config.workers);
        };
        defer conn.deinit();
        conn.setReadTimeout(5000);

        var rate_limiter = RateLimiter.init(self.config.rate_per_worker);

        var i: usize = 0;
        while (i < events.len) : (i += 1) {
            rate_limiter.wait();

            const start_ns = nostr.io.nanoTimestamp();

            if (i % 3 == 0) {
                // Read operation (query)
                const filter = nostr.Filter{
                    .kinds_slice = &[_]i32{1},
                    .limit_val = 10,
                };
                const filters = [_]nostr.Filter{filter};

                conn.sendReq("bench-sub", &filters) catch {
                    stats.recordError();
                    continue;
                };

                // Read until EOSE
                var received_eose = false;
                while (!received_eose) {
                    if (conn.receive(self.allocator)) |maybe_msg| {
                        if (maybe_msg) |msg| {
                            if (msg.msg_type == .eose) {
                                received_eose = true;
                            }
                        } else {
                            break;
                        }
                    } else |_| {
                        break;
                    }
                }

                conn.sendClose("bench-sub") catch {};

                const latency: i64 = @intCast(nostr.io.nanoTimestamp() - start_ns);
                try stats.recordSuccess(latency);
            } else {
                // Write operation
                conn.sendEvent(&events[i]) catch {
                    stats.recordError();
                    continue;
                };

                // Wait for OK
                if (conn.awaitOk(self.allocator)) |maybe_ok| {
                    if (maybe_ok) |ok| {
                        if (ok.success) {
                            const latency: i64 = @intCast(nostr.io.nanoTimestamp() - start_ns);
                            try stats.recordSuccess(latency);
                        } else {
                            stats.recordError();
                        }
                    }
                } else |_| {
                    stats.recordError();
                }
            }
        }

        stats.recordEnd();

        return BenchmarkResult.fromStats(&stats, "Mixed Read/Write", 1);
    }

    fn runQueryTest(self: *Benchmark) !BenchmarkResult {
        var stats = Stats.init(self.allocator);
        defer stats.deinit();

        // First, populate with some events
        const seed_events = try event_gen.generateEvents(self.allocator, &self.keypair, 1000);
        defer event_gen.freeEvents(self.allocator, seed_events);

        var conn = Conn.connect(self.allocator, self.config.relay_url) catch {
            stats.recordEnd();
            return BenchmarkResult.fromStats(&stats, "Query Performance", self.config.workers);
        };
        defer conn.deinit();
        conn.setReadTimeout(5000);

        // Seed the relay
        for (seed_events) |*ev| {
            conn.sendEvent(ev) catch continue;
            _ = conn.receive(self.allocator) catch continue;
        }

        stats.recordStart();

        // Run queries (capped at 1000 for reasonable test duration)
        const num_queries = @min(1000, self.config.num_events);
        var query_count: u32 = 0;

        const query_types = [_]nostr.Filter{
            .{ .kinds_slice = &[_]i32{1}, .limit_val = 100 },
            .{ .kinds_slice = &[_]i32{ 1, 6 }, .limit_val = 50 },
            .{ .limit_val = 10 },
        };

        while (query_count < num_queries) : (query_count += 1) {
            const filter = query_types[query_count % query_types.len];
            const filters = [_]nostr.Filter{filter};

            const start_ns = nostr.io.nanoTimestamp();

            var sub_buf: [32]u8 = undefined;
            const sub_id = std.fmt.bufPrint(&sub_buf, "q{d}", .{query_count}) catch "q0";

            conn.sendReq(sub_id, &filters) catch {
                stats.recordError();
                continue;
            };

            // Read until EOSE
            var received_eose = false;
            while (!received_eose) {
                if (conn.receive(self.allocator)) |maybe_msg| {
                    if (maybe_msg) |msg| {
                        if (msg.msg_type == .eose) {
                            received_eose = true;
                        }
                    } else {
                        break;
                    }
                } else |_| {
                    break;
                }
            }

            conn.sendClose(sub_id) catch {};

            const latency: i64 = @intCast(nostr.io.nanoTimestamp() - start_ns);
            if (received_eose) {
                try stats.recordSuccess(latency);
            } else {
                stats.recordError();
            }

            // Small delay between queries
            try std.Io.sleep(nostr.io.io(), .{ .nanoseconds = 1_000_000 }, .awake); // 1ms
        }

        stats.recordEnd();

        return BenchmarkResult.fromStats(&stats, "Query Performance", 1);
    }

    fn runConcurrentQueryStoreTest(self: *Benchmark) !BenchmarkResult {
        var stats = Stats.init(self.allocator);
        defer stats.deinit();

        const num_events = self.config.num_events / 2;
        const events = try event_gen.generateEvents(self.allocator, &self.keypair, num_events);
        defer event_gen.freeEvents(self.allocator, events);

        const seed_events = try event_gen.generateEvents(self.allocator, &self.keypair, 1000);
        defer event_gen.freeEvents(self.allocator, seed_events);

        var seed_conn = Conn.connect(self.allocator, self.config.relay_url) catch {
            stats.recordEnd();
            return BenchmarkResult.fromStats(&stats, "Concurrent Query/Store", self.config.workers);
        };
        defer seed_conn.deinit();
        seed_conn.setReadTimeout(5000);

        for (seed_events) |*ev| {
            seed_conn.sendEvent(ev) catch continue;
            _ = seed_conn.receive(self.allocator) catch continue;
        }

        stats.recordStart();

        const num_writers = self.config.workers / 2;
        const num_readers = self.config.workers - num_writers;
        const total_threads = num_writers + num_readers;

        const threads = try self.allocator.alloc(std.Thread, total_threads);
        defer self.allocator.free(threads);

        var shared_stats = SharedStats{
            .stats = &stats,
            .mu = .init,
        };

        const events_per_writer = if (num_writers > 0) events.len / num_writers else 0;

        for (0..num_writers) |i| {
            const start_idx = i * events_per_writer;
            const end_idx = if (i == num_writers - 1) events.len else start_idx + events_per_writer;
            const worker_events = events[start_idx..end_idx];

            threads[i] = try std.Thread.spawn(.{}, workerThread, .{
                self.config.relay_url,
                worker_events,
                &shared_stats,
                self.config.rate_per_worker,
            });
        }

        // Cap queries per reader for reasonable test duration (250 max = 1000 total with 4 readers)
        const queries_per_reader: u32 = @min(250, @as(u32, @intCast(self.config.num_events)) / 4);

        for (num_writers..total_threads) |i| {
            threads[i] = try std.Thread.spawn(.{}, queryWorkerThread, .{
                self.config.relay_url,
                queries_per_reader,
                &shared_stats,
            });
        }

        for (threads) |thread| {
            thread.join();
        }

        stats.recordEnd();

        return BenchmarkResult.fromStats(&stats, "Concurrent Query/Store", self.config.workers);
    }

    fn runSearchTest(self: *Benchmark) !BenchmarkResult {
        var stats = Stats.init(self.allocator);
        defer stats.deinit();

        const seed_events = try event_gen.generateSearchableEvents(self.allocator, &self.keypair, 1000);
        defer event_gen.freeEvents(self.allocator, seed_events);

        var conn = Conn.connect(self.allocator, self.config.relay_url) catch {
            stats.recordEnd();
            return BenchmarkResult.fromStats(&stats, "NIP-50 Search", 1);
        };
        defer conn.deinit();
        conn.setReadTimeout(5000);

        for (seed_events) |*ev| {
            conn.sendEvent(ev) catch continue;
            _ = conn.receive(self.allocator) catch continue;
        }

        stats.recordStart();

        const search_queries = [_][]const u8{
            "bitcoin",
            "nostr",
            "lightning",
            "satoshi",
            "zap",
        };

        const num_queries = self.config.num_events;
        var query_count: u32 = 0;

        while (query_count < num_queries) : (query_count += 1) {
            const search_term = search_queries[query_count % search_queries.len];
            const filter = nostr.Filter{
                .kinds_slice = &[_]i32{1},
                .search_str = search_term,
                .limit_val = 50,
            };
            const filters = [_]nostr.Filter{filter};

            const start_ns = nostr.io.nanoTimestamp();

            var sub_buf: [32]u8 = undefined;
            const sub_id = std.fmt.bufPrint(&sub_buf, "s{d}", .{query_count}) catch "s0";

            conn.sendReq(sub_id, &filters) catch {
                stats.recordError();
                continue;
            };

            var received_eose = false;
            while (!received_eose) {
                if (conn.receive(self.allocator)) |maybe_msg| {
                    if (maybe_msg) |msg| {
                        if (msg.msg_type == .eose) {
                            received_eose = true;
                        }
                    } else {
                        break;
                    }
                } else |_| {
                    break;
                }
            }

            conn.sendClose(sub_id) catch {};

            const latency: i64 = @intCast(nostr.io.nanoTimestamp() - start_ns);
            try stats.recordSuccess(latency);
        }

        stats.recordEnd();

        return BenchmarkResult.fromStats(&stats, "NIP-50 Search", 1);
    }

    pub fn printReport(self: *Benchmark) void {
        std.debug.print("\n", .{});
        std.debug.print("════════════════════════════════════════════════════════════\n", .{});
        std.debug.print("                    BENCHMARK REPORT                        \n", .{});
        std.debug.print("════════════════════════════════════════════════════════════\n", .{});
        std.debug.print("Relay: {s}\n", .{self.config.relay_url});
        std.debug.print("Workers: {d}\n", .{self.config.workers});
        std.debug.print("Events: {d}\n", .{self.config.num_events});

        for (self.results.items) |result| {
            result.print();
        }

        std.debug.print("\n", .{});
        std.debug.print("════════════════════════════════════════════════════════════\n", .{});

        // Summary table
        std.debug.print("\nSummary Table:\n", .{});
        std.debug.print("┌─────────────────────┬───────────┬───────────┬───────────┐\n", .{});
        std.debug.print("│ Test                │ Events/s  │ Avg (ms)  │ P99 (ms)  │\n", .{});
        std.debug.print("├─────────────────────┼───────────┼───────────┼───────────┤\n", .{});

        for (self.results.items) |result| {
            const avg_ms = @as(f64, @floatFromInt(result.avg_latency_ns)) / 1_000_000.0;
            const p99_ms = @as(f64, @floatFromInt(result.p99_latency_ns)) / 1_000_000.0;
            std.debug.print("│ {s: <19} │ {d: >9.1} │ {d: >9.2} │ {d: >9.2} │\n", .{
                result.test_name,
                result.events_per_second,
                avg_ms,
                p99_ms,
            });
        }

        std.debug.print("└─────────────────────┴───────────┴───────────┴───────────┘\n", .{});
    }

    pub fn writeJsonReport(self: *Benchmark, path: []const u8, relay_name: ?[]const u8, relay_commit: ?[]const u8) !void {
        const io = nostr.io.io();
        const file = try std.Io.Dir.cwd().createFile(io, path, .{});
        defer file.close(io);

        var buf: [512]u8 = undefined;

        try file.writeStreamingAll(io, "{\n");
        try writeReportLine(file, io, &buf, "  \"relay_url\": \"{s}\",\n", .{self.config.relay_url});
        if (relay_name) |name| {
            try writeReportLine(file, io, &buf, "  \"relay_name\": \"{s}\",\n", .{name});
        }
        if (relay_commit) |commit| {
            try writeReportLine(file, io, &buf, "  \"relay_commit\": \"{s}\",\n", .{commit});
        }
        try writeReportLine(file, io, &buf, "  \"workers\": {d},\n", .{self.config.workers});
        try writeReportLine(file, io, &buf, "  \"num_events\": {d},\n", .{self.config.num_events});
        try writeReportLine(file, io, &buf, "  \"async_mode\": {s},\n", .{if (self.config.async_publish) "true" else "false"});
        try file.writeStreamingAll(io, "  \"results\": [\n");

        for (self.results.items, 0..) |result, i| {
            try file.writeStreamingAll(io, "    {\n");
            try writeReportLine(file, io, &buf, "      \"test\": \"{s}\",\n", .{result.test_name});
            try writeReportLine(file, io, &buf, "      \"events_per_second\": {d:.2},\n", .{result.events_per_second});
            try writeReportLine(file, io, &buf, "      \"avg_latency_ms\": {d:.3},\n", .{msFromNs(result.avg_latency_ns)});
            try writeReportLine(file, io, &buf, "      \"p50_latency_ms\": {d:.3},\n", .{msFromNs(result.p50_latency_ns)});
            try writeReportLine(file, io, &buf, "      \"p90_latency_ms\": {d:.3},\n", .{msFromNs(result.p90_latency_ns)});
            try writeReportLine(file, io, &buf, "      \"p95_latency_ms\": {d:.3},\n", .{msFromNs(result.p95_latency_ns)});
            try writeReportLine(file, io, &buf, "      \"p99_latency_ms\": {d:.3},\n", .{msFromNs(result.p99_latency_ns)});
            try writeReportLine(file, io, &buf, "      \"success_rate\": {d:.1},\n", .{result.success_rate});
            try writeReportLine(file, io, &buf, "      \"total_events\": {d},\n", .{result.total_events});
            try writeReportLine(file, io, &buf, "      \"errors\": {d}\n", .{result.errors});
            if (i < self.results.items.len - 1) {
                try file.writeStreamingAll(io, "    },\n");
            } else {
                try file.writeStreamingAll(io, "    }\n");
            }
        }

        try file.writeStreamingAll(io, "  ]\n");
        try file.writeStreamingAll(io, "}\n");

        std.debug.print("\nReport written to: {s}\n", .{path});
    }
};

fn msFromNs(ns: i64) f64 {
    return @as(f64, @floatFromInt(ns)) / 1_000_000.0;
}

/// Formats one JSON line into the scratch buffer and streams it to the file.
fn writeReportLine(file: anytype, io: std.Io, buf: []u8, comptime fmt: []const u8, args: anytype) !void {
    const formatted = std.fmt.bufPrint(buf, fmt, args) catch return error.BufferTooSmall;
    try file.writeStreamingAll(io, formatted);
}

const SharedStats = struct {
    stats: *Stats,
    // Workers are OS threads (std.Thread.spawn) and nostr.io is the process-global
    // blocking (thread-backed) Io, so this Mutex provides real cross-thread mutual
    // exclusion. This relies on that blocking-io model, not an event-loop io.
    mu: std.Io.Mutex,

    fn recordError(self: *SharedStats) void {
        self.mu.lockUncancelable(nostr.io.io());
        defer self.mu.unlock(nostr.io.io());
        self.stats.recordError();
    }

    fn recordSuccess(self: *SharedStats, latency: i64) void {
        self.mu.lockUncancelable(nostr.io.io());
        defer self.mu.unlock(nostr.io.io());
        self.stats.recordSuccess(latency) catch {};
    }

    fn recordRateLimited(self: *SharedStats, latency: i64) void {
        self.mu.lockUncancelable(nostr.io.io());
        defer self.mu.unlock(nostr.io.io());
        self.stats.recordRateLimited(latency) catch {};
    }
};

fn workerThread(
    relay_url: []const u8,
    events: []const Event,
    shared: *SharedStats,
    rate_per_sec: u32,
) void {
    const allocator = std.heap.c_allocator;
    var conn = Conn.connect(allocator, relay_url) catch return;
    defer conn.deinit();

    conn.setReadTimeout(5000);

    var rate_limiter = RateLimiter.init(rate_per_sec);

    for (events) |*ev| {
        rate_limiter.wait();

        const start_ns = nostr.io.nanoTimestamp();

        conn.sendEvent(ev) catch {
            shared.recordError();
            continue;
        };

        // Wait for OK response
        if (conn.awaitOk(allocator)) |maybe_ok| {
            if (maybe_ok) |ok| {
                const latency: i64 = @intCast(nostr.io.nanoTimestamp() - start_ns);
                if (ok.success or ok.is_duplicate) {
                    shared.recordSuccess(latency);
                } else if (ok.is_rate_limited) {
                    shared.recordRateLimited(latency);
                } else {
                    shared.recordError();
                }
            }
        } else |_| {
            shared.recordError();
        }
    }
}

fn queryWorkerThread(
    relay_url: []const u8,
    num_queries: u32,
    shared: *SharedStats,
) void {
    const allocator = std.heap.c_allocator;
    var conn = Conn.connect(allocator, relay_url) catch return;
    defer conn.deinit();

    conn.setReadTimeout(5000);

    const query_types = [_]nostr.Filter{
        .{ .kinds_slice = &[_]i32{1}, .limit_val = 100 },
        .{ .kinds_slice = &[_]i32{ 1, 6 }, .limit_val = 50 },
        .{ .limit_val = 10 },
    };

    var query_count: u32 = 0;
    while (query_count < num_queries) : (query_count += 1) {
        const filter = query_types[query_count % query_types.len];
        const filters = [_]nostr.Filter{filter};

        const start_ns = nostr.io.nanoTimestamp();

        var sub_buf: [32]u8 = undefined;
        const sub_id = std.fmt.bufPrint(&sub_buf, "q{d}", .{query_count}) catch "q0";

        conn.sendReq(sub_id, &filters) catch {
            shared.recordError();
            continue;
        };

        var received_eose = false;
        var recv_count: u32 = 0;
        const max_recv: u32 = 200;
        while (!received_eose and recv_count < max_recv) : (recv_count += 1) {
            if (conn.receive(allocator)) |maybe_msg| {
                if (maybe_msg) |msg| {
                    if (msg.msg_type == .eose) {
                        received_eose = true;
                    }
                } else {
                    break;
                }
            } else |_| {
                break;
            }
        }

        conn.sendClose(sub_id) catch {};

        const latency: i64 = @intCast(nostr.io.nanoTimestamp() - start_ns);
        if (received_eose) {
            shared.recordSuccess(latency);
        } else {
            shared.recordError();
        }

        std.Io.sleep(nostr.io.io(), .{ .nanoseconds = 1_000_000 }, .awake) catch {};
    }
}

fn asyncWorkerThread(
    relay_url: []const u8,
    events: []const Event,
    shared: *SharedStats,
    rate_per_sec: u32,
) void {
    const allocator = std.heap.c_allocator;
    var conn = Conn.connect(allocator, relay_url) catch return;
    defer conn.deinit();

    var rate_limiter = RateLimiter.init(rate_per_sec);

    for (events) |*ev| {
        rate_limiter.wait();

        const start_ns = nostr.io.nanoTimestamp();

        conn.sendEvent(ev) catch {
            shared.recordError();
            continue;
        };

        const latency: i64 = @intCast(nostr.io.nanoTimestamp() - start_ns);
        shared.recordSuccess(latency);
    }
}
