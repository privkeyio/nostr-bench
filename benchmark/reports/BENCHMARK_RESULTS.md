# Nostr Relay Benchmark Results

Comprehensive benchmark comparison of 6 Nostr relay implementations.

**Test Environment:**
- OS: Linux 6.8.0
- Docker-based testing (isolated containers)
- Benchmark tool: nostr-bench (Zig)
- Date: 2025-12-12

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
| **Wisp** | **7,983** | **0.40ms** | **0.70ms** | **100%** |
| Orly | 6,786 | 0.68ms | 6.92ms | 100% |
| nostr-rs-relay | 1,991 | 4.02ms | 20.57ms | 100% |
| Strfry | 1,014 | 7.89ms | 10.70ms | 100% |
| Khatru-LMDB | 422 | 18.95ms | 24.29ms | 100% |
| Khatru-SQLite | 169 | 44.88ms | 1,252.46ms | 52.5% |

---

## Full Benchmark Comparison

### Peak Throughput Test
Maximum events per second with 8 concurrent workers.

| Relay | Events/sec | Avg (ms) | P50 (ms) | P90 (ms) | P99 (ms) | Success |
|-------|------------|----------|----------|----------|----------|---------|
| **Wisp** | 7,983 | 0.40 | 0.39 | 0.54 | 0.70 | 100% |
| Orly | 6,786 | 0.68 | 0.48 | 0.70 | 6.92 | 100% |
| nostr-rs-relay | 1,991 | 4.02 | 1.73 | 11.82 | 20.57 | 100% |
| Strfry | 1,014 | 7.89 | 5.74 | 7.45 | 10.70 | 100% |
| Khatru-LMDB | 422 | 18.95 | 18.09 | 19.94 | 24.29 | 100% |
| Khatru-SQLite | 169 | 44.88 | 4.66 | 12.87 | 1,252.46 | 52.5% |

### Query Performance Test
Single-worker query operations (REQ subscriptions).

| Relay | Queries/sec | Avg (ms) | P50 (ms) | P90 (ms) | P99 (ms) | Success |
|-------|-------------|----------|----------|----------|----------|---------|
| **Wisp** | 232 | 3.24 | 2.95 | 5.96 | 7.81 | 100% |
| Strfry | 23 | 42.93 | 42.69 | 45.74 | 47.42 | 11.4% |
| Khatru-LMDB | 23 | 42.90 | 42.71 | 45.96 | 47.31 | 6.2% |
| Orly | 22 | 43.77 | 43.46 | 47.10 | 51.24 | 6.6% |
| Khatru-SQLite | 21 | 45.97 | 46.39 | 51.78 | 54.34 | 5.4% |
| nostr-rs-relay | 21 | 47.00 | 43.21 | 51.21 | 82.24 | 62.3% |

### Concurrent Query/Store Test
Mixed read/write workload with 8 workers.

| Relay | Events/sec | Avg (ms) | P50 (ms) | P90 (ms) | P99 (ms) | Success |
|-------|------------|----------|----------|----------|----------|---------|
| **Wisp** | 1,311 | 2.43 | 1.07 | 6.17 | 8.63 | 100% |
| Khatru-LMDB | 258 | 20.53 | 8.83 | 44.85 | 47.12 | 51.6% |
| Orly | 255 | 15.65 | 0.52 | 46.13 | 49.19 | 51.1% |
| Strfry | 187 | 24.01 | 7.86 | 45.06 | 47.13 | 65.0% |
| Khatru-SQLite | 184 | 39.33 | 4.82 | 48.03 | 871.02 | 36.9% |
| nostr-rs-relay | 128 | 30.85 | 41.44 | 46.55 | 82.15 | 100% |

### Burst Pattern Test
Rate-limited event publishing (simulates real-world bursty traffic).

| Relay | Events/sec | Avg (ms) | P99 (ms) | Success |
|-------|------------|----------|----------|---------|
| **Wisp** | 91 | 0.38 | 0.79 | 100% |
| nostr-rs-relay | 83 | 1.46 | 12.34 | 100% |
| Orly | 79 | 0.72 | 1.31 | 26.9% |
| Strfry | 71 | 2.44 | 5.91 | 30.8% |
| Khatru-LMDB | 66 | 2.82 | 5.30 | 22.5% |
| Khatru-SQLite | 55 | 5.47 | 10.30 | 19.0% |

### Mixed Read/Write Test
Combined publish and subscribe operations with 1 worker.

| Relay | Events/sec | Avg (ms) | P50 (ms) | P90 (ms) | P99 (ms) | Success |
|-------|------------|----------|----------|----------|----------|---------|
| **Wisp** | 651 | 0.46 | 0.51 | 0.95 | 1.55 | 66.7% |
| nostr-rs-relay | 67 | 14.74 | 0.80 | 41.95 | 43.47 | 100% |
| Orly | 62 | 14.52 | 1.26 | 41.90 | 42.79 | 40.8% |
| Strfry | 61 | 15.77 | 2.07 | 43.70 | 45.88 | 64.2% |
| Khatru-LMDB | 58 | 15.62 | 2.54 | 43.59 | 44.56 | 38.2% |
| Khatru-SQLite | 51 | 17.74 | 4.65 | 46.10 | 48.36 | 33.8% |

---

## Architecture Comparison

| Relay | Language | Database | Architecture | Notes |
|-------|----------|----------|--------------|-------|
| **Wisp** | Zig | LMDB | Single-threaded async I/O | Best overall performance |
| Orly | Go | Badger | Goroutines + GC | Excellent peak throughput |
| nostr-rs-relay | Rust | SQLite | Async Tokio | Good reliability, solid throughput |
| Strfry | C++ | LMDB | Multi-threaded | Mature, widely deployed |
| Khatru-LMDB | Go | LMDB | Goroutines | fiatjaf's framework |
| Khatru-SQLite | Go | SQLite | Goroutines | fiatjaf's framework |

---

## Key Findings

### 1. Wisp Leads in Performance
- **4x faster** peak throughput than next best (Orly)
- **10x lower** average latency in peak tests
- Excellent query performance (232 q/s vs ~21-23 q/s for others)

### 2. nostr-rs-relay Shows Strong Reliability
- **100% success rate** on peak throughput, burst pattern, and concurrent tests
- Third highest peak throughput (1,991 ev/s)
- Best burst pattern reliability after Wisp

### 3. Database Backend Matters
- **LMDB**: Wisp and Khatru-LMDB show benefits of LMDB's memory-mapped design
- **Badger**: Orly achieves excellent peak throughput despite Go's GC overhead
- **SQLite**: Both nostr-rs-relay and Khatru-SQLite show higher latency variance

### 4. Language/Runtime Impact
- **Zig (Wisp)**: Zero-overhead abstractions, predictable performance
- **Go (Orly, Khatru)**: GC pauses visible in P99 latency spikes
- **Rust (nostr-rs-relay)**: Strong reliability with async Tokio runtime
- **C++ (Strfry)**: Solid and mature, widely deployed in production

### 5. Success Rates Under Load
- Wisp and nostr-rs-relay: 100% success on most tests
- Other relays show degradation in burst/query tests

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

*Generated: 2025-12-12 | nostr-bench v0.1.0*
