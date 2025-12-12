# nostr-bench

Nostr relay benchmark tool written in Zig.

## Build

```bash
zig build -Doptimize=ReleaseFast
```

## Usage

```bash
# Benchmark a relay
./zig-out/bin/nostr-bench -r ws://localhost:7777

# Multiple relays
./zig-out/bin/nostr-bench -r ws://localhost:7777 -r ws://localhost:7778

# Custom parameters
./zig-out/bin/nostr-bench -r ws://localhost:7777 -e 10000 -w 8 --rate 1000
```

## Options

```
-r, --relay <URL>       Relay WebSocket URL (can specify multiple)
-e, --events <N>        Number of events (default: 10000)
-w, --workers <N>       Concurrent workers (default: CPU/4)
-d, --duration <S>      Duration in seconds (default: 60)
--rate <N>              Events/sec per worker (default: 100)
--async                 Fire-and-forget mode
--report-file <PATH>    Write JSON report
--only-peak             Run only peak throughput test
--only-burst            Run only burst pattern test
--only-mixed            Run only mixed read/write test
--only-query            Run only query performance test
--only-concurrent       Run only concurrent query/store test
```

## License

LGPL v2.1
