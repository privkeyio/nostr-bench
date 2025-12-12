#!/bin/bash

# Setup script for nostr-bench
# Creates necessary directories for the benchmark suite
# All relay code is cloned automatically by Docker during build

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=============================================="
echo "  NOSTR-BENCH SETUP"
echo "=============================================="
echo ""

# Create directories
mkdir -p "${SCRIPT_DIR}/data"
mkdir -p "${SCRIPT_DIR}/reports"
mkdir -p "${SCRIPT_DIR}/configs"

echo "Creating data directories..."
mkdir -p "${SCRIPT_DIR}/data"/{wisp,orly,strfry,nostr-rs-relay,khatru-sqlite,khatru-lmdb,relayer}
chmod -R 777 "${SCRIPT_DIR}/data" 2>/dev/null || true

echo ""
echo "=============================================="
echo "  SETUP COMPLETE"
echo "=============================================="
echo ""
echo "Data directories: ${SCRIPT_DIR}/data"
echo "Reports directory: ${SCRIPT_DIR}/reports"
echo ""
echo "All relay source code will be cloned automatically"
echo "by Docker during the build process."
echo ""
echo "To run the benchmark:"
echo "  ./run-benchmark.sh"
echo ""
echo "Or with custom settings:"
echo "  ./run-benchmark.sh --quick --relays wisp,strfry"
echo "  ./run-benchmark.sh --ramdisk --events 50000"
echo ""
