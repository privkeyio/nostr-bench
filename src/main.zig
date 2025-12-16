const std = @import("std");
const benchmark = @import("benchmark.zig");
const nostr = @import("nostr.zig");
const relay = @import("relay.zig");

pub fn main() !void {
    const allocator = std.heap.c_allocator;

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

    for (config.relays) |url| {
        try manager.addRelay(url);
    }

    const relays = manager.getRelays();
    if (relays.len == 0) {
        std.debug.print("No relays specified. Use --relay flag.\n", .{});
        printUsage();
        return;
    }

    for (relays) |r| {
        std.debug.print("\n────────────────────────────────────────────────────────────\n", .{});
        std.debug.print("Benchmarking: {s}\n", .{r.displayName()});
        std.debug.print("URL: {s}\n", .{r.url});
        std.debug.print("Workers: {d}\n", .{config.workers});
        std.debug.print("Events: {d}\n", .{config.num_events});
        std.debug.print("Duration: {d}s\n", .{config.duration_secs});
        if (config.rate_per_worker == 0) {
            std.debug.print("Rate limit: unlimited\n", .{});
        } else {
            std.debug.print("Rate limit: {d} events/sec per worker\n", .{config.rate_per_worker});
        }
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
            .run_concurrent_rw = config.run_concurrent_rw,
            .run_search = config.run_search,
            .async_publish = config.async_publish,
        };

        var bench = try benchmark.Benchmark.init(allocator, bench_config);
        defer bench.deinit();

        bench.run() catch |err| {
            std.debug.print("Benchmark failed for {s}: {}\n", .{ r.displayName(), err });
            continue;
        };
        bench.printReport();

        if (config.report_file) |path| {
            bench.writeJsonReport(path, config.relay_name, config.relay_commit) catch |err| {
                std.debug.print("Failed to write report: {}\n", .{err});
            };
        }
    }
}

pub const Config = struct {
    relay_url: []const u8 = "",
    workers: u32,
    num_events: u32,
    duration_secs: u32,
    rate_per_worker: u32,
    report_dir: []const u8,
    report_file: ?[]const u8 = null,
    relay_name: ?[]const u8 = null,
    relay_commit: ?[]const u8 = null,
    relays: []const []const u8 = &[_][]const u8{},
    run_peak_throughput: bool = true,
    run_burst_pattern: bool = true,
    run_mixed_rw: bool = true,
    run_query: bool = true,
    run_concurrent_rw: bool = true,
    run_search: bool = true,
    async_publish: bool = false,
};

fn parseArgs(allocator: std.mem.Allocator) !Config {
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    _ = args.skip();

    var relay_list = std.ArrayListUnmanaged([]const u8){};

    var config = Config{
        .workers = @intCast(@max(2, (std.Thread.getCpuCount() catch 4) / 4)),
        .num_events = 10000,
        .duration_secs = 60,
        .rate_per_worker = 1000,
        .report_dir = "/tmp/benchmark_reports",
        .relays = &[_][]const u8{},
    };

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printUsage();
            std.process.exit(0);
        } else if (std.mem.eql(u8, arg, "--relay") or std.mem.eql(u8, arg, "-r")) {
            try relay_list.append(allocator, args.next() orelse return error.MissingValue);
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
            config.run_concurrent_rw = false;
            config.run_search = false;
        } else if (std.mem.eql(u8, arg, "--only-burst")) {
            config.run_peak_throughput = false;
            config.run_mixed_rw = false;
            config.run_query = false;
            config.run_concurrent_rw = false;
            config.run_search = false;
        } else if (std.mem.eql(u8, arg, "--only-mixed")) {
            config.run_peak_throughput = false;
            config.run_burst_pattern = false;
            config.run_query = false;
            config.run_concurrent_rw = false;
            config.run_search = false;
        } else if (std.mem.eql(u8, arg, "--only-query")) {
            config.run_peak_throughput = false;
            config.run_burst_pattern = false;
            config.run_mixed_rw = false;
            config.run_concurrent_rw = false;
            config.run_search = false;
        } else if (std.mem.eql(u8, arg, "--only-concurrent")) {
            config.run_peak_throughput = false;
            config.run_burst_pattern = false;
            config.run_mixed_rw = false;
            config.run_query = false;
            config.run_search = false;
        } else if (std.mem.eql(u8, arg, "--only-search")) {
            config.run_peak_throughput = false;
            config.run_burst_pattern = false;
            config.run_mixed_rw = false;
            config.run_query = false;
            config.run_concurrent_rw = false;
        } else if (std.mem.eql(u8, arg, "--async")) {
            config.async_publish = true;
        } else if (std.mem.eql(u8, arg, "--report-file")) {
            config.report_file = args.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, arg, "--relay-name")) {
            config.relay_name = args.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, arg, "--relay-commit")) {
            config.relay_commit = args.next() orelse return error.MissingValue;
        }
    }

    config.relays = relay_list.items;
    return config;
}

fn printUsage() void {
    const usage =
        \\Nostr Relay Benchmark
        \\
        \\USAGE:
        \\    nostr-bench [OPTIONS]
        \\
        \\OPTIONS:
        \\    -r, --relay <URL>       Relay WebSocket URL (can be specified multiple times)
        \\    -w, --workers <N>       Number of concurrent workers (default: CPU/4)
        \\    -e, --events <N>        Number of events to generate (default: 10000)
        \\    -d, --duration <SECS>   Test duration in seconds (default: 60)
        \\    --rate <N>              Events per second per worker (default: 1000, 0 = unlimited)
        \\    --async                 Fire-and-forget mode (don't wait for OK)
        \\    --report-file <PATH>    Write JSON report to file
        \\    --relay-name <NAME>     Relay name for report (e.g., "wisp")
        \\    --relay-commit <HASH>   Relay commit hash for report
        \\
        \\TEST MODES:
        \\    --only-peak             Run only peak throughput test
        \\    --only-burst            Run only burst pattern test
        \\    --only-mixed            Run only mixed read/write test
        \\    --only-query            Run only query performance test
        \\    --only-concurrent       Run only concurrent query/store test
        \\    --only-search           Run only NIP-50 search test
        \\
        \\EXAMPLES:
        \\    nostr-bench -r ws://localhost:7777 -e 10000 -w 8 --rate 1000
        \\    nostr-bench -r ws://localhost:7777 --async --only-peak
        \\
    ;
    std.debug.print("{s}", .{usage});
}

test "parse args" {
    _ = Config{
        .workers = 4,
        .num_events = 10000,
        .duration_secs = 60,
        .rate_per_worker = 100,
        .report_dir = "/tmp/benchmark_reports",
    };
}
