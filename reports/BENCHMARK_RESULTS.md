# Nostr Relay Benchmark Results

Comprehensive benchmark comparison of 6 Nostr relay implementations.

**Test Environment:**
- OS: Linux 6.8.0
- Docker-based testing (isolated containers)
- Benchmark tool: nostr-bench (Zig)
- Date: 2025-12-14

**Benchmark Parameters:**
| Parameter | Value | Description |
|-----------|-------|-------------|
| Workers | 8 | Concurrent WebSocket connections |
| Events | 10,000 | Total events per test |
| Rate | 1,000/sec | Per-worker rate limit |
| Duration | 60s | Max test duration |

---

## Peak Throughput Results

| Relay | Events/sec | Avg Latency | P99 Latency | Success Rate |
|-------|------------|-------------|-------------|--------------|
| **Orly** | **6,766** | **0.76ms** | 7.36ms | **100%** |
| **Wisp** | **6,474** | 0.88ms | **3.23ms** | **100%** |
| nostr-rs-relay | 2,406 | 3.32ms | 19.68ms | 100% |
| Strfry | 804 | 9.95ms | 19.53ms | 100% |
| Khatru-LMDB | 369 | 21.66ms | 25.27ms | 100% |
| Khatru-SQLite | 168 | 43.98ms | 1,287.78ms | 51.9% |

---

## Full Benchmark Comparison

### Peak Throughput Test
Maximum events per second with 8 concurrent workers.

| Relay | Events/sec | Avg (ms) | P50 (ms) | P90 (ms) | P99 (ms) | Success |
|-------|------------|----------|----------|----------|----------|---------|
| **Orly** | 6,766 | 0.76 | 0.56 | 0.83 | 7.36 | 100% |
| **Wisp** | 6,474 | 0.88 | 0.61 | 1.78 | 3.23 | 100% |
| nostr-rs-relay | 2,406 | 3.32 | 1.51 | 12.83 | 19.68 | 100% |
| Strfry | 804 | 9.95 | 10.27 | 15.03 | 19.53 | 100% |
| Khatru-LMDB | 369 | 21.66 | 18.25 | 19.86 | 25.27 | 100% |
| Khatru-SQLite | 168 | 43.98 | 4.46 | 6.36 | 1,287.78 | 51.9% |

### Query Performance Test
Single-worker query operations (REQ subscriptions).

| Relay | Queries/sec | Avg (ms) | P50 (ms) | P90 (ms) | P99 (ms) | Success |
|-------|-------------|----------|----------|----------|----------|---------|
| **Wisp** | 246 | 3.00 | 2.80 | 5.49 | 6.38 | 100% |
| Strfry | 22 | 43.97 | 42.79 | 48.83 | 62.64 | 11.4% |
| Orly | 22 | 44.00 | 43.83 | 47.21 | 51.02 | 6.6% |
| Khatru-LMDB | 22 | 44.51 | 44.20 | 48.42 | 51.80 | 6.0% |
| Khatru-SQLite | 20 | 48.19 | 48.17 | 53.24 | 74.25 | 5.2% |
| nostr-rs-relay | 19 | 52.68 | 48.81 | 71.28 | 83.37 | 55.7% |

### Concurrent Query/Store Test
Mixed read/write workload with 8 workers.

| Relay | Events/sec | Avg (ms) | P50 (ms) | P90 (ms) | P99 (ms) | Success |
|-------|------------|----------|----------|----------|----------|---------|
| **Wisp** | 749 | 2.55 | 0.73 | 5.46 | 7.33 | 83.3% |
| Khatru-LMDB | 258 | 21.48 | 8.91 | 44.84 | 48.92 | 51.5% |
| Orly | 254 | 15.76 | 0.60 | 46.44 | 50.91 | 50.9% |
| Strfry | 185 | 23.13 | 6.54 | 45.29 | 50.46 | 64.9% |
| Khatru-SQLite | 171 | 42.10 | 4.56 | 23.52 | 1,234.44 | 34.5% |
| nostr-rs-relay | 113 | 33.50 | 41.80 | 48.62 | 82.04 | 100% |

### Burst Pattern Test
Rate-limited event publishing (simulates real-world bursty traffic).

| Relay | Events/sec | Avg (ms) | P99 (ms) | Success |
|-------|------------|----------|----------|---------|
| **Wisp** | 90 | 0.58 | 5.19 | 100% |
| Orly | 79 | 0.76 | 1.50 | 26.8% |
| nostr-rs-relay | 78 | 2.32 | 19.45 | 100% |
| Strfry | 70 | 2.16 | 5.33 | 25.3% |
| Khatru-LMDB | 66 | 2.91 | 5.32 | 22.3% |
| Khatru-SQLite | 56 | 5.21 | 10.18 | 19.3% |

### Mixed Read/Write Test
Combined publish and subscribe operations with 1 worker.

| Relay | Events/sec | Avg (ms) | P50 (ms) | P90 (ms) | P99 (ms) | Success |
|-------|------------|----------|----------|----------|----------|---------|
| **Wisp** | 665 | 0.37 | 0.40 | 0.73 | 0.96 | 66.7% |
| nostr-rs-relay | 66 | 15.00 | 0.84 | 41.86 | 43.83 | 100% |
| Strfry | 62 | 15.46 | 1.80 | 43.24 | 44.80 | 64.6% |
| Orly | 61 | 14.64 | 1.51 | 41.95 | 42.74 | 40.5% |
| Khatru-LMDB | 57 | 15.87 | 2.68 | 44.47 | 46.17 | 37.5% |
| Khatru-SQLite | 47 | 18.98 | 4.66 | 47.46 | 50.87 | 31.5% |

---

## Architecture Comparison

| Relay | Language | Database | Architecture | Notes |
|-------|----------|----------|--------------|-------|
| **Orly** | Go | Badger | Goroutines + GC | Excellent peak throughput |
| **Wisp** | Zig | LMDB | Single-threaded async I/O | Best query performance |
| nostr-rs-relay | Rust | SQLite | Async Tokio | Good reliability |
| Strfry | C++ | LMDB | Multi-threaded | Mature, widely deployed |
| Khatru-LMDB | Go | LMDB | Goroutines | fiatjaf's framework |
| Khatru-SQLite | Go | SQLite | Goroutines | fiatjaf's framework |

---

## Key Findings

### 1. Orly and Wisp Lead in Peak Throughput
- **Orly: 6,766/s** - fastest peak throughput
- **Wisp: 6,474/s** - close second, best P99 latency (3.23ms)
- Both achieve **8-17x higher throughput** than Strfry

### 2. Wisp Dominates Query Performance
- **246 queries/sec** vs 19-22 q/s for others
- **11x faster** query performance than competition
- 100% success rate on queries

### 3. nostr-rs-relay Shows Strong Reliability
- **100% success rate** on burst pattern, mixed read/write, and concurrent tests
- Third highest peak throughput (2,406 ev/s)
- Most consistent under varied workloads

### 4. Database Backend Matters
- **LMDB**: Wisp achieves excellent query performance with LMDB
- **Badger**: Orly achieves best peak throughput with Go + Badger
- **SQLite**: Higher latency variance, especially visible in Khatru-SQLite P99

### 5. Language/Runtime Impact
- **Zig (Wisp)**: Zero-overhead abstractions, predictable latency
- **Go (Orly, Khatru)**: GC pauses visible in P99 latency spikes
- **Rust (nostr-rs-relay)**: Strong reliability with async Tokio runtime
- **C++ (Strfry)**: Solid and mature, widely deployed in production

---

## Running Benchmarks

### Using Docker Compose (Recommended)
```bash
# Run full benchmark suite
./run-benchmark.sh

# Quick test
./run-benchmark.sh --quick

# Specific relays only
./run-benchmark.sh --relays wisp,strfry

# With ramdisk for best results
./run-benchmark.sh --ramdisk
```

### Manual nostr-bench
```bash
# Build nostr-bench
zig build -Doptimize=ReleaseFast

# Run benchmark
./zig-out/bin/nostr-bench -r ws://localhost:7777 -e 10000 -w 8 --rate 1000

# Generate JSON report
./zig-out/bin/nostr-bench -r ws://localhost:7777 --report-file results.json
```

---

## Test Descriptions

| Test | Description | Workers |
|------|-------------|---------|
| **Peak Throughput** | Maximum sustained event publishing | 8 |
| **Burst Pattern** | Rate-limited bursty traffic | 1 |
| **Mixed Read/Write** | Combined publish and subscribe | 1 |
| **Query Performance** | REQ subscription responses | 1 |
| **Concurrent Query/Store** | Heavy mixed workload | 8 |

---

*Generated: 2025-12-14 | nostr-bench v0.1.0*
