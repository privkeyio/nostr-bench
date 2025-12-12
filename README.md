# nostr-bench

A fast Nostr relay benchmarking tool written in Zig.

## Build

```bash
zig build -Doptimize=ReleaseFast
```

## Usage

```bash
# Basic benchmark
./zig-out/bin/nostr-bench -r ws://localhost:7777

# Multiple relays
./zig-out/bin/nostr-bench -r ws://localhost:7777 -r ws://localhost:3334

# Custom parameters
./zig-out/bin/nostr-bench -r ws://localhost:7777 -e 10000 -w 8 --rate 1000

# Async mode (fire-and-forget)
./zig-out/bin/nostr-bench -r ws://localhost:7777 --async --only-peak

# Generate JSON report
./zig-out/bin/nostr-bench -r ws://localhost:7777 --report-file results.json --relay-name wisp --relay-commit abc123
```

## Options

| Flag | Description | Default |
|------|-------------|---------|
| `-r, --relay <URL>` | Relay WebSocket URL (repeatable) | - |
| `-e, --events <N>` | Number of events | 10000 |
| `-w, --workers <N>` | Worker threads | CPU/4 |
| `-d, --duration <S>` | Duration in seconds | 60 |
| `--rate <N>` | Events/sec per worker | 100 |
| `--async` | Fire-and-forget mode | false |
| `--report-file <PATH>` | Write JSON report to file | - |
| `--relay-name <NAME>` | Relay name for report | - |
| `--relay-commit <HASH>` | Relay commit hash for report | - |

## Test Modes

Run specific tests only:

| Flag | Test |
|------|------|
| `--only-peak` | Peak throughput |
| `--only-burst` | Burst pattern |
| `--only-mixed` | Mixed read/write |
| `--only-query` | Query performance |
| `--only-concurrent` | Concurrent query/store |

## Benchmark Results

See [benchmark/reports/BENCHMARK_RESULTS.md](benchmark/reports/BENCHMARK_RESULTS.md) for comparison data.

## License

LGPL v2.1 - See [LICENSE](LICENSE)
