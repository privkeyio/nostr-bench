const std = @import("std");
const benchmark = @import("benchmark.zig");
const nostr = @import("nostr.zig");
const relay = @import("relay.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const config = parseArgs(allocator) catch |err| {
        std.debug.print("Error parsing arguments: {}\n", .{err});
        printUsage();
        return;
    };

    try nostr.init();
    defer nostr.cleanup();

    std.debug.print("\n", .{});
    std.debug.print("╔══════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║         NOSTR RELAY BENCHMARK                            ║\n", .{});
    std.debug.print("╚══════════════════════════════════════════════════════════╝\n", .{});
    std.debug.print("\n", .{});

    var manager = relay.RelayManager.init(allocator);
    defer manager.deinit();

    if (config.relay_url.len > 0) {
        _ = try manager.addRelayUrl(config.relay_url);
    } else {
        for (config.relays) |kind| {
            _ = try manager.addRelay(kind, null);
        }
    }

    const relays = manager.getRelays();
    if (relays.len == 0) {
        std.debug.print("No relays specified. Use --relay or --relays flag.\n", .{});
        printUsage();
        return;
    }

    for (relays) |r| {
        std.debug.print("\n────────────────────────────────────────────────────────────\n", .{});
        std.debug.print("Benchmarking: {s}\n", .{r.kind.displayName()});
        std.debug.print("URL: {s}\n", .{r.url});
        std.debug.print("Workers: {d}\n", .{config.workers});
        std.debug.print("Events: {d}\n", .{config.num_events});
        std.debug.print("Duration: {d}s\n", .{config.duration_secs});
        std.debug.print("Rate limit: {d} events/sec per worker\n", .{config.rate_per_worker});
        std.debug.print("────────────────────────────────────────────────────────────\n", .{});

        const bench_config = Config{
            .relay_url = r.url,
            .workers = config.workers,
            .num_events = config.num_events,
            .duration_secs = config.duration_secs,
            .rate_per_worker = config.rate_per_worker,
            .report_dir = config.report_dir,
            .run_peak_throughput = config.run_peak_throughput,
            .run_burst_pattern = config.run_burst_pattern,
            .run_mixed_rw = config.run_mixed_rw,
            .run_query = config.run_query,
        };

        var bench = try benchmark.Benchmark.init(allocator, bench_config);
        defer bench.deinit();

        bench.run() catch |err| {
            std.debug.print("Benchmark failed for {s}: {}\n", .{ r.kind.displayName(), err });
            continue;
        };
        bench.printReport();
    }
}

pub const Config = struct {
    relay_url: []const u8,
    workers: u32,
    num_events: u32,
    duration_secs: u32,
    rate_per_worker: u32,
    report_dir: []const u8,
    relays: []const relay.RelayKind = &[_]relay.RelayKind{},
    run_peak_throughput: bool = true,
    run_burst_pattern: bool = true,
    run_mixed_rw: bool = true,
    run_query: bool = true,
};

fn parseArgs(allocator: std.mem.Allocator) !Config {
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    _ = args.skip();

    var config = Config{
        .relay_url = "",
        .workers = @intCast(@max(2, (std.Thread.getCpuCount() catch 4) / 4)),
        .num_events = 10000,
        .duration_secs = 60,
        .rate_per_worker = 100,
        .report_dir = "/tmp/benchmark_reports",
        .relays = &[_]relay.RelayKind{ .orly, .wisp },
    };

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printUsage();
            std.process.exit(0);
        } else if (std.mem.eql(u8, arg, "--relay") or std.mem.eql(u8, arg, "-r")) {
            config.relay_url = args.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, arg, "--relays")) {
            const relay_arg = args.next() orelse return error.MissingValue;
            config.relays = try relay.parseRelayList(allocator, relay_arg);
        } else if (std.mem.eql(u8, arg, "--workers") or std.mem.eql(u8, arg, "-w")) {
            const val = args.next() orelse return error.MissingValue;
            config.workers = try std.fmt.parseInt(u32, val, 10);
        } else if (std.mem.eql(u8, arg, "--events") or std.mem.eql(u8, arg, "-e")) {
            const val = args.next() orelse return error.MissingValue;
            config.num_events = try std.fmt.parseInt(u32, val, 10);
        } else if (std.mem.eql(u8, arg, "--duration") or std.mem.eql(u8, arg, "-d")) {
            const val = args.next() orelse return error.MissingValue;
            config.duration_secs = try std.fmt.parseInt(u32, val, 10);
        } else if (std.mem.eql(u8, arg, "--rate")) {
            const val = args.next() orelse return error.MissingValue;
            config.rate_per_worker = try std.fmt.parseInt(u32, val, 10);
        } else if (std.mem.eql(u8, arg, "--report-dir")) {
            config.report_dir = args.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, arg, "--only-peak")) {
            config.run_burst_pattern = false;
            config.run_mixed_rw = false;
            config.run_query = false;
        } else if (std.mem.eql(u8, arg, "--only-burst")) {
            config.run_peak_throughput = false;
            config.run_mixed_rw = false;
            config.run_query = false;
        } else if (std.mem.eql(u8, arg, "--only-mixed")) {
            config.run_peak_throughput = false;
            config.run_burst_pattern = false;
            config.run_query = false;
        } else if (std.mem.eql(u8, arg, "--only-query")) {
            config.run_peak_throughput = false;
            config.run_burst_pattern = false;
            config.run_mixed_rw = false;
        }
    }

    return config;
}

fn printUsage() void {
    const usage =
        \\Nostr Relay Benchmark
        \\
        \\USAGE:
        \\    nostr-relay-benchmark [OPTIONS]
        \\
        \\OPTIONS:
        \\    -r, --relay <URL>       Single relay WebSocket URL (overrides --relays)
        \\    --relays <LIST>         Comma-separated relay names: orly,wisp (default: orly,wisp)
        \\    -w, --workers <N>       Number of concurrent workers (default: CPU/4)
        \\    -e, --events <N>        Number of events to generate (default: 10000)
        \\    -d, --duration <SECS>   Test duration in seconds (default: 60)
        \\    --rate <N>              Events per second per worker (default: 100)
        \\    --report-dir <PATH>     Directory for reports (default: /tmp/benchmark_reports)
        \\
        \\TEST MODES:
        \\    --only-peak             Run only peak throughput test
        \\    --only-burst            Run only burst pattern test
        \\    --only-mixed            Run only mixed read/write test
        \\    --only-query            Run only query performance test
        \\
        \\SUPPORTED RELAYS:
        \\    orly                    Orly relay (next.orly.dev) - default port 8080
        \\    wisp                    Wisp relay - default port 7777
        \\
        \\EXAMPLES:
        \\    nostr-relay-benchmark --relays orly,wisp
        \\    nostr-relay-benchmark --relays orly -w 8 -e 50000
        \\    nostr-relay-benchmark -r ws://localhost:8080
        \\    nostr-relay-benchmark --relays wisp --only-peak
        \\
    ;
    std.debug.print("{s}", .{usage});
}

test "parse args" {
    _ = Config{
        .relay_url = "ws://localhost:8080",
        .workers = 4,
        .num_events = 10000,
        .duration_secs = 60,
        .rate_per_worker = 100,
        .report_dir = "/tmp/benchmark_reports",
    };
}
