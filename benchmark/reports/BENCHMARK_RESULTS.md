# Nostr Relay Benchmark Results

Benchmark comparison between Nostr relays.

**Test Environment:**
- OS: Linux 6.8.0
- CPU: AMD/Intel (local machine)
- Benchmark tool: nostr-bench (Zig)
- Date: 2025-12-12

## Summary Comparison

| Relay | Peak (ev/s) | Avg Latency | P99 Latency | Success Rate |
|-------|-------------|-------------|-------------|--------------|
| **Wisp** | **7,861** | **0.73ms** | **1.16ms** | **100%** |
| Orly | 2,540 | 2.93ms | 16.52ms | 100% |
| Strfry | 1,507 | 5.30ms | 8.74ms | 100% |

## Performance Comparison

| Metric | Wisp | Orly | Strfry |
|--------|------|------|--------|
| **Peak Throughput** | 7,861 ev/s | 2,540 ev/s | 1,507 ev/s |
| **Peak Avg Latency** | 0.73ms | 2.93ms | 5.30ms |
| **Peak P99 Latency** | 1.16ms | 16.52ms | 8.74ms |
| **Query Performance** | 225 q/s | 22 q/s | 22 q/s |
| **Query P99 Latency** | 6.05ms | 51.23ms | 63.29ms |
| **Concurrent Query/Store** | 1,167 ev/s | 255 ev/s | 186 ev/s |
| **Burst Success Rate** | 100% | 26.8% | 23.8% |

## Async Mode (Fire-and-Forget)

| Relay | Async Peak (ev/s) | Avg Latency | P99 Latency |
|-------|-------------------|-------------|-------------|
| **Wisp** | **15,593** | **8.56us** | **15.89us** |
| Strfry | 15,418 | 9.84us | 33.78us |
| Orly | 14,847 | 8.06us | 29.74us |

In async mode (fire-and-forget without waiting for OK), all relays achieve similar throughput (~15k ev/s), limited by network send rate rather than database write speed.

## Architecture Comparison

| Relay | Language | Database | Architecture |
|-------|----------|----------|--------------|
| **Wisp** | Zig | LMDB | Single-threaded async I/O |
| Strfry | C++ | LMDB | Multi-threaded |
| Orly | Go | Badger | Goroutines + GC |

## Running Benchmarks

```bash
# Build nostr-bench
zig build -Doptimize=ReleaseFast

# Run full benchmark suite
./zig-out/bin/nostr-bench -r ws://localhost:7777 -e 10000 -w 8 --rate 1000

# Run async mode benchmark
./zig-out/bin/nostr-bench -r ws://localhost:7777 -e 10000 -w 8 --async --only-peak
```

### Benchmark Parameters

| Parameter | Value | Description |
|-----------|-------|-------------|
| Workers | 8 | Concurrent connections |
| Events | 10,000 | Total events per test |
| Rate | 1,000/sec | Per-worker rate limit |
| Duration | 60s | Max test duration |
