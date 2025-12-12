# Dockerfile for Wisp relay (Zig-based)
FROM debian:bookworm-slim AS builder

RUN apt-get update && apt-get install -y \
    curl \
    xz-utils \
    ca-certificates \
    git \
    libsecp256k1-dev \
    libssl-dev \
    liblmdb-dev \
    && rm -rf /var/lib/apt/lists/*

# Install Zig 0.15.2
RUN curl -L https://ziglang.org/download/0.15.2/zig-x86_64-linux-0.15.2.tar.xz | tar -xJ -C /opt
ENV PATH="/opt/zig-x86_64-linux-0.15.2:$PATH"

WORKDIR /build

# Clone wisp from GitHub
RUN git clone --depth 1 https://github.com/privkeyio/wisp.git .

# Build wisp
RUN zig build -Doptimize=ReleaseFast

FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y \
    ca-certificates \
    curl \
    liblmdb0 \
    libsecp256k1-1 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY --from=builder /build/zig-out/bin/wisp /app/wisp

RUN mkdir -p /data && chmod 777 /data

ENV WISP_HOST=0.0.0.0
ENV WISP_PORT=7777
ENV WISP_STORAGE_PATH=/data/wisp.lmdb

EXPOSE 7777

HEALTHCHECK --interval=10s --timeout=5s --start-period=5s --retries=5 \
    CMD curl -f http://localhost:7777/ || exit 1

CMD ["/app/wisp"]
