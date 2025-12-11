const std = @import("std");
const nostr = @import("nostr.zig");
const websocket = @import("websocket.zig");
const stats_mod = @import("stats.zig");
const event_gen = @import("event_generator.zig");

const Config = @import("main.zig").Config;
const Stats = stats_mod.Stats;
const BenchmarkResult = stats_mod.BenchmarkResult;
const RateLimiter = stats_mod.RateLimiter;

pub const Benchmark = struct {
    allocator: std.mem.Allocator,
    config: Config,
    results: std.ArrayListUnmanaged(BenchmarkResult),
    keypair: nostr.Keypair,

    pub fn init(allocator: std.mem.Allocator, config: Config) !Benchmark {
        return .{
            .allocator = allocator,
            .config = config,
            .results = .{},
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
    }

    fn runPeakThroughputTest(self: *Benchmark) !BenchmarkResult {
        var stats = Stats.init(self.allocator);
        defer stats.deinit();

        const events = try event_gen.generateEvents(self.allocator, &self.keypair, self.config.num_events);
        defer {
            for (events) |*ev| {
                ev.deinit();
            }
            self.allocator.free(events);
        }

        stats.recordStart();

        // Run workers in parallel
        const threads = try self.allocator.alloc(std.Thread, self.config.workers);
        defer self.allocator.free(threads);

        var shared_stats = SharedStats{
            .stats = &stats,
            .mu = .{},
        };

        const events_per_worker = events.len / self.config.workers;

        for (threads, 0..) |*thread, i| {
            const start_idx = i * events_per_worker;
            const end_idx = if (i == self.config.workers - 1) events.len else start_idx + events_per_worker;
            const worker_events = events[start_idx..end_idx];

            thread.* = try std.Thread.spawn(.{}, workerThread, .{
                self.config.relay_url,
                worker_events,
                &shared_stats,
                self.config.rate_per_worker,
                self.allocator,
            });
        }

        for (threads) |thread| {
            thread.join();
        }

        stats.recordEnd();

        return BenchmarkResult.fromStats(&stats, "Peak Throughput", self.config.workers);
    }

    fn runBurstPatternTest(self: *Benchmark) !BenchmarkResult {
        var stats = Stats.init(self.allocator);
        defer stats.deinit();

        const events = try event_gen.generateEvents(self.allocator, &self.keypair, self.config.num_events);
        defer {
            for (events) |*ev| {
                ev.deinit();
            }
            self.allocator.free(events);
        }

        stats.recordStart();

        // Burst pattern: send events in bursts with pauses between
        const burst_size = self.config.num_events / 10;
        const quiet_period_ns: u64 = 500_000_000; // 500ms
        const burst_interval_ns: u64 = 10_000_000; // 10ms between events in burst

        var event_idx: usize = 0;
        var client = try websocket.Client.init(self.allocator, self.config.relay_url);
        defer client.deinit();

        client.connect() catch {
            stats.recordEnd();
            return BenchmarkResult.fromStats(&stats, "Burst Pattern", self.config.workers);
        };

        while (event_idx < events.len) {
            // Burst
            const burst_end = @min(event_idx + burst_size, events.len);
            while (event_idx < burst_end) : (event_idx += 1) {
                const start_ns = std.time.nanoTimestamp();

                client.sendEvent(&events[event_idx]) catch {
                    stats.recordError();
                    continue;
                };

                // Wait for OK response (with timeout)
                if (client.receive()) |response| {
                    if (response) |data| {
                        const msg = nostr.RelayMsg.parse(data, self.allocator) catch {
                            stats.recordError();
                            continue;
                        };
                        if (msg.msg_type == .ok and msg.success) {
                            const latency: i64 = @intCast(std.time.nanoTimestamp() - start_ns);
                            try stats.recordSuccess(latency);
                        } else {
                            stats.recordError();
                        }
                    }
                } else |_| {
                    stats.recordError();
                }

                std.Thread.sleep(burst_interval_ns);
            }

            // Quiet period
            std.Thread.sleep(quiet_period_ns);
        }

        stats.recordEnd();

        return BenchmarkResult.fromStats(&stats, "Burst Pattern", 1);
    }

    fn runMixedReadWriteTest(self: *Benchmark) !BenchmarkResult {
        var stats = Stats.init(self.allocator);
        defer stats.deinit();

        const num_events = self.config.num_events / 2; // Half for write
        const events = try event_gen.generateEvents(self.allocator, &self.keypair, num_events);
        defer {
            for (events) |*ev| {
                ev.deinit();
            }
            self.allocator.free(events);
        }

        stats.recordStart();

        var client = try websocket.Client.init(self.allocator, self.config.relay_url);
        defer client.deinit();

        client.connect() catch {
            stats.recordEnd();
            return BenchmarkResult.fromStats(&stats, "Mixed Read/Write", self.config.workers);
        };

        var rate_limiter = RateLimiter.init(self.config.rate_per_worker);

        var i: usize = 0;
        while (i < events.len) : (i += 1) {
            rate_limiter.wait();

            const start_ns = std.time.nanoTimestamp();

            if (i % 3 == 0) {
                // Read operation (query)
                const filter = nostr.Filter{
                    .kinds = &[_]i32{1},
                    .limit = 10,
                };
                const filters = [_]nostr.Filter{filter};

                client.sendReq("bench-sub", &filters) catch {
                    stats.recordError();
                    continue;
                };

                // Read until EOSE
                var received_eose = false;
                while (!received_eose) {
                    if (client.receive()) |response| {
                        if (response) |data| {
                            const msg = nostr.RelayMsg.parse(data, self.allocator) catch continue;
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

                client.sendClose("bench-sub") catch {};

                const latency: i64 = @intCast(std.time.nanoTimestamp() - start_ns);
                try stats.recordSuccess(latency);
            } else {
                // Write operation
                client.sendEvent(&events[i]) catch {
                    stats.recordError();
                    continue;
                };

                // Wait for OK
                if (client.receive()) |response| {
                    if (response) |data| {
                        const msg = nostr.RelayMsg.parse(data, self.allocator) catch {
                            stats.recordError();
                            continue;
                        };
                        if (msg.msg_type == .ok and msg.success) {
                            const latency: i64 = @intCast(std.time.nanoTimestamp() - start_ns);
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
        defer {
            for (seed_events) |*ev| {
                ev.deinit();
            }
            self.allocator.free(seed_events);
        }

        var client = try websocket.Client.init(self.allocator, self.config.relay_url);
        defer client.deinit();

        client.connect() catch {
            stats.recordEnd();
            return BenchmarkResult.fromStats(&stats, "Query Performance", self.config.workers);
        };

        // Seed the relay
        for (seed_events) |*ev| {
            client.sendEvent(ev) catch continue;
            _ = client.receive() catch continue;
        }

        stats.recordStart();

        // Run queries
        const num_queries = self.config.num_events;
        var query_count: u32 = 0;

        const query_types = [_]nostr.Filter{
            .{ .kinds = &[_]i32{1}, .limit = 100 },
            .{ .kinds = &[_]i32{ 1, 6 }, .limit = 50 },
            .{ .limit = 10 },
        };

        while (query_count < num_queries) : (query_count += 1) {
            const filter = query_types[query_count % query_types.len];
            const filters = [_]nostr.Filter{filter};

            const start_ns = std.time.nanoTimestamp();

            var sub_buf: [32]u8 = undefined;
            const sub_id = std.fmt.bufPrint(&sub_buf, "q{d}", .{query_count}) catch "q0";

            client.sendReq(sub_id, &filters) catch {
                stats.recordError();
                continue;
            };

            // Read until EOSE
            var received_eose = false;
            while (!received_eose) {
                if (client.receive()) |response| {
                    if (response) |data| {
                        const msg = nostr.RelayMsg.parse(data, self.allocator) catch continue;
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

            client.sendClose(sub_id) catch {};

            const latency: i64 = @intCast(std.time.nanoTimestamp() - start_ns);
            try stats.recordSuccess(latency);

            // Small delay between queries
            std.Thread.sleep(1_000_000); // 1ms
        }

        stats.recordEnd();

        return BenchmarkResult.fromStats(&stats, "Query Performance", 1);
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
};

const SharedStats = struct {
    stats: *Stats,
    mu: std.Thread.Mutex,
};

fn workerThread(
    relay_url: []const u8,
    events: []const nostr.Event,
    shared: *SharedStats,
    rate_per_sec: u32,
    allocator: std.mem.Allocator,
) void {
    _ = allocator;
    var client = websocket.Client.init(std.heap.page_allocator, relay_url) catch return;
    defer client.deinit();

    client.connect() catch return;

    var rate_limiter = RateLimiter.init(rate_per_sec);

    for (events) |*ev| {
        rate_limiter.wait();

        const start_ns = std.time.nanoTimestamp();

        client.sendEvent(ev) catch {
            shared.mu.lock();
            shared.stats.recordError();
            shared.mu.unlock();
            continue;
        };

        // Wait for OK response
        if (client.receive()) |response| {
            if (response) |data| {
                const msg = nostr.RelayMsg.parse(data, std.heap.page_allocator) catch {
                    shared.mu.lock();
                    shared.stats.recordError();
                    shared.mu.unlock();
                    continue;
                };

                const latency: i64 = @intCast(std.time.nanoTimestamp() - start_ns);
                if (msg.msg_type == .ok and (msg.success or msg.is_duplicate)) {
                    shared.mu.lock();
                    shared.stats.recordSuccess(latency) catch {};
                    shared.mu.unlock();
                } else if (msg.msg_type == .ok and msg.is_rate_limited) {
                    shared.mu.lock();
                    shared.stats.recordRateLimited(latency) catch {};
                    shared.mu.unlock();
                } else if (msg.msg_type == .ok) {
                    shared.mu.lock();
                    shared.stats.recordError();
                    shared.mu.unlock();
                } else {
                    shared.mu.lock();
                    shared.stats.recordError();
                    shared.mu.unlock();
                }
            }
        } else |_| {
            shared.mu.lock();
            shared.stats.recordError();
            shared.mu.unlock();
        }
    }
}
