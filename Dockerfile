FROM debian:bookworm-slim AS builder

RUN apt-get update && apt-get install -y \
    curl \
    xz-utils \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

RUN curl -L https://ziglang.org/download/0.15.0-dev.834+c94d18985/zig-linux-x86_64-0.15.0-dev.834+c94d18985.tar.xz | tar -xJ -C /opt
ENV PATH="/opt/zig-linux-x86_64-0.15.0-dev.834+c94d18985:$PATH"

WORKDIR /app
COPY . .

RUN zig build -Doptimize=ReleaseFast

FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /app/zig-out/bin/nostr-relay-benchmark /usr/local/bin/

ENTRYPOINT ["nostr-relay-benchmark"]
