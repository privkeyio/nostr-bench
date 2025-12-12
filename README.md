# nostr-bench

A fast Nostr relay benchmarking tool written in Zig.

## Build

```bash
zig build
```

## Usage

```bash
./zig-out/bin/nostr-bench -r ws://localhost:3334
./zig-out/bin/nostr-bench -r ws://localhost:3334 -r ws://localhost:7777
./zig-out/bin/nostr-bench -r ws://localhost:3334 -e 5000 -w 8
```

## Options

| Flag | Description | Default |
|------|-------------|---------|
| `-r, --relay` | Relay URL (repeatable) | - |
| `-e` | Number of events | 10000 |
| `-w` | Worker threads | CPU/4 |
| `-d` | Duration in seconds | 60 |

## License

LGPL v2.1 - See [LICENSE](LICENSE)
