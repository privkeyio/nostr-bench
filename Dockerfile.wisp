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

# Install Zig 0.16.0, verified against the sha256 from
# ziglang.org/download/index.json before it is extracted
ARG ZIG_VERSION=0.16.0
ARG ZIG_SHA256=70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00
RUN curl -fsSL -o /tmp/zig.tar.xz https://ziglang.org/download/${ZIG_VERSION}/zig-x86_64-linux-${ZIG_VERSION}.tar.xz && \
    echo "${ZIG_SHA256}  /tmp/zig.tar.xz" | sha256sum -c - && \
    tar -xJf /tmp/zig.tar.xz -C /opt && rm /tmp/zig.tar.xz
ENV PATH="/opt/zig-x86_64-linux-${ZIG_VERSION}:$PATH"

WORKDIR /build

# Clone a pinned wisp release; the build fails if the tag no longer points at
# the expected commit
ARG WISP_VERSION=v0.7.0
ARG WISP_COMMIT=f5f3dbbec55392b45c380782d1cb0c74e371f873
RUN git clone --depth 1 --branch ${WISP_VERSION} https://github.com/privkeyio/wisp.git . && \
    test "$(git rev-parse HEAD)" = "${WISP_COMMIT}"

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
