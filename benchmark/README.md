# Wisp Benchmark Suite

Performance benchmarks for the Wisp Nostr relay.

## Quick Start

```bash
# Build wisp with optimizations
zig build -Doptimize=ReleaseFast

# Build nostr-bench (in sibling directory)
cd ../nostr-bench && zig build -Doptimize=ReleaseFast && cd -

# Start wisp with fresh database
rm -rf /tmp/wisp-bench && mkdir -p /tmp/wisp-bench
WISP_DATA_DIR=/tmp/wisp-bench ./zig-out/bin/wisp &

# Run full benchmark suite
../nostr-bench/zig-out/bin/nostr-bench -r ws://localhost:7777 -e 10000 -w 8 --rate 1000
```

## Benchmark Tests

### 1. Peak Throughput Test
- Tests maximum event ingestion rate
- Concurrent workers pushing events as fast as possible
- Measures events/second, latency distribution, success rate

### 2. Burst Pattern Test
- Simulates real-world traffic patterns
- Alternating high-activity bursts and quiet periods
- Tests relay behavior under varying loads

### 3. Mixed Read/Write Test
- Concurrent read (REQ) and write (EVENT) operations
- Tests query performance while events are being ingested
- Measures combined throughput and latency

### 4. Query Performance Test
- Pre-populates database with events
- Runs rapid-fire queries with various filters
- Measures query latency and throughput

## Results

See [reports/BENCHMARK_RESULTS.md](reports/BENCHMARK_RESULTS.md) for detailed results comparing Wisp against other relays.

### Quick Summary

| Relay | Peak (ev/s) | Avg Latency | P99 Latency | Success Rate |
|-------|-------------|-------------|-------------|--------------|
| **Wisp** | **6,007** | **1.23ms** | **4.24ms** | **100%** |
| Strfry | 1,350 | 5.92ms | 10.88ms | 100% |
| Orly | 1,259 | 6.07ms | 31.60ms | 100% |

**Wisp Advantages:**
- **4.5-4.8x faster** peak throughput than Strfry and Orly
- **2.6-7.5x better** P99 latency
- **8x faster** query performance
- **100% success rate** on all tests (vs 12-25% for others on burst/query)

## Benchmark Tool

Uses [nostr-bench](https://github.com/privkeyio/nostr-bench), a Zig-based Nostr relay benchmark tool.

### Parameters

| Flag | Description | Default |
|------|-------------|---------|
| `-r` | Relay WebSocket URL | required |
| `-e` | Number of events | 10000 |
| `-w` | Number of workers | 4 |
| `--rate` | Events/sec per worker | 500 |
| `--duration` | Test duration | 60s |
| `--only-peak` | Run only peak throughput test | false |

### Example Commands

```bash
# Quick test
../nostr-bench/zig-out/bin/nostr-bench -r ws://localhost:7777 -e 1000 -w 4 --only-peak

# Full benchmark with 8 workers
../nostr-bench/zig-out/bin/nostr-bench -r ws://localhost:7777 -e 10000 -w 8 --rate 1000

# High load test
../nostr-bench/zig-out/bin/nostr-bench -r ws://localhost:7777 -e 50000 -w 16 --rate 2000
```

## Comparing Against Other Relays

### Orly (Go + Badger)

```bash
# Start orly
cd ../next.orly.dev && ./orly --db /tmp/orly-bench --listen 127.0.0.1:3334 --acl none &

# Benchmark
../nostr-bench/zig-out/bin/nostr-bench -r ws://localhost:3334 -e 10000 -w 8 --rate 1000
```

### Strfry (C++ + LMDB)

```bash
# Start strfry (if installed)
strfry relay &

# Benchmark
../nostr-bench/zig-out/bin/nostr-bench -r ws://localhost:7777 -e 10000 -w 8 --rate 1000
```

## Performance Metrics

### Latency Percentiles

- **P50**: Median latency
- **P90**: 90th percentile - most users experience this or better
- **P95**: 95th percentile
- **P99**: 99th percentile - tail latency indicator

### Throughput

- **Events/sec**: Sustained event write rate
- **Queries/sec**: Sustained query rate

### Success Rate

- Percentage of operations that completed without timeout or error
- 100% is ideal; lower rates indicate relay overload

## Tuning Wisp for Benchmarks

### LMDB Settings

```toml
[storage]
map_size_mb = 10240  # 10GB - increase for large datasets
```

### System Tuning

```bash
# Increase file descriptor limit
ulimit -n 65536

# For high connection counts
sysctl -w net.core.somaxconn=65535
sysctl -w net.ipv4.tcp_max_syn_backlog=65535
```
