#!/bin/bash

# Nostr Relay Benchmark Runner
# Tests multiple relay implementations with nostr-bench
#
# Usage:
#   ./run-benchmark.sh                    # Run all relays
#   ./run-benchmark.sh --relays wisp,strfry  # Run specific relays
#   ./run-benchmark.sh --ramdisk          # Use /dev/shm for data
#   ./run-benchmark.sh --quick            # Quick test (1000 events)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

# Defaults
USE_RAMDISK=false
QUICK_MODE=false
SELECTED_RELAYS=""
BENCHMARK_EVENTS="${BENCHMARK_EVENTS:-10000}"
BENCHMARK_WORKERS="${BENCHMARK_WORKERS:-8}"
BENCHMARK_DURATION="${BENCHMARK_DURATION:-60}"
BENCHMARK_RATE="${BENCHMARK_RATE:-1000}"

# All available relays (relayer excluded - requires PostgreSQL)
ALL_RELAYS="wisp,orly,strfry,nostr-rs-relay,khatru-sqlite,khatru-lmdb"

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --ramdisk)
            USE_RAMDISK=true
            shift
            ;;
        --quick)
            QUICK_MODE=true
            BENCHMARK_EVENTS=1000
            BENCHMARK_DURATION=30
            shift
            ;;
        --relays)
            SELECTED_RELAYS="$2"
            shift 2
            ;;
        --events)
            BENCHMARK_EVENTS="$2"
            shift 2
            ;;
        --workers)
            BENCHMARK_WORKERS="$2"
            shift 2
            ;;
        --duration)
            BENCHMARK_DURATION="$2"
            shift 2
            ;;
        --rate)
            BENCHMARK_RATE="$2"
            shift 2
            ;;
        --help|-h)
            echo "Nostr Relay Benchmark Suite"
            echo ""
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --relays <list>    Comma-separated list of relays to test"
            echo "                     Available: wisp,orly,strfry,nostr-rs-relay,khatru-sqlite,khatru-lmdb"
            echo "  --ramdisk          Use /dev/shm for relay data (faster, requires 8GB+ RAM)"
            echo "  --quick            Quick test mode (1000 events, 30s duration)"
            echo "  --events <n>       Number of events per test (default: 10000)"
            echo "  --workers <n>      Number of concurrent workers (default: 8)"
            echo "  --duration <s>     Test duration in seconds (default: 60)"
            echo "  --rate <n>         Events per second per worker (default: 1000)"
            echo "  --help, -h         Show this help"
            echo ""
            echo "Examples:"
            echo "  $0                           # Benchmark all relays"
            echo "  $0 --relays wisp,strfry      # Only test wisp and strfry"
            echo "  $0 --quick --relays wisp    # Quick test of wisp only"
            echo "  $0 --ramdisk --events 50000 # Heavy benchmark with ramdisk"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

# Determine docker compose command
if docker compose version &> /dev/null 2>&1; then
    DOCKER_COMPOSE="docker compose"
else
    DOCKER_COMPOSE="docker-compose"
fi

# Export environment variables
export BENCHMARK_EVENTS
export BENCHMARK_WORKERS
export BENCHMARK_DURATION
export BENCHMARK_RATE

echo "=============================================="
echo "  NOSTR RELAY BENCHMARK SUITE"
echo "=============================================="
echo ""
echo "Configuration:"
echo "  Events: ${BENCHMARK_EVENTS}"
echo "  Workers: ${BENCHMARK_WORKERS}"
echo "  Duration: ${BENCHMARK_DURATION}s"
echo "  Rate: ${BENCHMARK_RATE}/s per worker"
if [ "$USE_RAMDISK" = true ]; then
    echo "  Storage: /dev/shm (ramdisk)"
else
    echo "  Storage: ./data (disk)"
fi
echo ""

# Setup data directories
if [ "$USE_RAMDISK" = true ]; then
    DATA_BASE="/dev/shm/nostr-bench"

    if [ ! -d "/dev/shm" ]; then
        echo "ERROR: /dev/shm is not available"
        exit 1
    fi

    # Check available space
    SHM_AVAILABLE_KB=$(df /dev/shm | tail -1 | awk '{print $4}')
    SHM_AVAILABLE_GB=$((SHM_AVAILABLE_KB / 1024 / 1024))

    if [ "$SHM_AVAILABLE_KB" -lt 8388608 ]; then
        echo "WARNING: Less than 8GB available in /dev/shm (${SHM_AVAILABLE_GB}GB)"
        echo "Consider: sudo mount -o remount,size=16G /dev/shm"
    fi

    rm -rf "${DATA_BASE}" 2>/dev/null || sudo rm -rf "${DATA_BASE}" 2>/dev/null || true
    mkdir -p "${DATA_BASE}"

    # Override data volume mounts
    export DATA_DIR="${DATA_BASE}"
else
    DATA_BASE="./data"

    # Clean old data
    if [ -d "${DATA_BASE}" ]; then
        echo "Cleaning old data..."
        rm -rf "${DATA_BASE}" 2>/dev/null || sudo rm -rf "${DATA_BASE}" 2>/dev/null || true
    fi
fi

# Create data directories
mkdir -p "${DATA_BASE}"/{wisp,orly,strfry,nostr-rs-relay,khatru-sqlite,khatru-lmdb}
chmod -R 777 "${DATA_BASE}" 2>/dev/null || true

# Create reports directory
mkdir -p ./reports

# Stop any running containers
echo "Stopping any existing containers..."
$DOCKER_COMPOSE down -v 2>/dev/null || true

# Determine which services to start
if [ -n "$SELECTED_RELAYS" ]; then
    # Convert comma-separated to space-separated
    SERVICES=$(echo "$SELECTED_RELAYS" | tr ',' ' ')
    SERVICES="${SERVICES} benchmark"
else
    SERVICES=""  # All services
fi

echo ""
echo "Building and starting containers..."
echo ""

if [ -n "$SERVICES" ]; then
    $DOCKER_COMPOSE up --build --exit-code-from benchmark --abort-on-container-exit $SERVICES
else
    $DOCKER_COMPOSE up --build --exit-code-from benchmark --abort-on-container-exit
fi

# Cleanup
cleanup() {
    echo ""
    echo "Cleaning up..."
    $DOCKER_COMPOSE down -v 2>/dev/null || true

    if [ "$USE_RAMDISK" = true ]; then
        rm -rf "${DATA_BASE}" 2>/dev/null || sudo rm -rf "${DATA_BASE}" 2>/dev/null || true
    fi
}

trap cleanup EXIT

echo ""
echo "=============================================="
echo "  BENCHMARK COMPLETE"
echo "=============================================="
echo ""
echo "Reports saved to: ${SCRIPT_DIR}/reports/"
ls -la ./reports/*.json 2>/dev/null || echo "No JSON reports found"
