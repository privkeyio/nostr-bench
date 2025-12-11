#!/bin/bash
set -e

RELAYS="${1:-orly,wisp}"
EVENTS="${2:-10000}"
WORKERS="${3:-4}"

echo "Starting relay benchmark..."
echo "Relays: $RELAYS"
echo "Events: $EVENTS"
echo "Workers: $WORKERS"

if command -v docker-compose &> /dev/null; then
    COMPOSE_CMD="docker-compose"
elif command -v docker &> /dev/null && docker compose version &> /dev/null; then
    COMPOSE_CMD="docker compose"
else
    echo "Running locally (no Docker)"
    zig build -Doptimize=ReleaseFast
    ./zig-out/bin/nostr-relay-benchmark --relays "$RELAYS" -e "$EVENTS" -w "$WORKERS"
    exit 0
fi

mkdir -p reports

$COMPOSE_CMD down -v 2>/dev/null || true
$COMPOSE_CMD up --build --abort-on-container-exit benchmark

$COMPOSE_CMD down -v
