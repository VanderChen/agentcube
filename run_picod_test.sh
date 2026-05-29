#!/bin/bash
# PicoD Automated Benchmark Script
# Runs multi-dimensional tests on PicoD

set -e

# Configuration
PICOD_IMAGE="picod:test"
CONTAINER_NAME="picod-bench"
PICOD_PORT="8080"
BOOTSTRAP_PRIVATE_KEY="/tmp/bootstrap_private_key.pem"
BOOTSTRAP_PUBLIC_KEY="/tmp/bootstrap_public_key.pem"
RESULTS_DIR="results_$(date +%Y%m%d_%H%M%S)"
OUTPUT_CSV="${RESULTS_DIR}/benchmark_results.csv"

# Dimensions
CPU_LIMITS=("0.5" "1.0")
CONCURRENCIES=(5 10 20)

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

mkdir -p "$RESULTS_DIR"

cleanup() {
    if docker ps -a | grep -q "$CONTAINER_NAME"; then
        docker stop "$CONTAINER_NAME" >/dev/null 2>&1 || true
        docker rm "$CONTAINER_NAME" >/dev/null 2>&1 || true
    fi
}

generate_keys() {
    if [ ! -f "$BOOTSTRAP_PRIVATE_KEY" ]; then
        echo -e "${BLUE}🔑 Generating EC P-256 keys...${NC}"
        openssl ecparam -name prime256v1 -genkey -noout -out "$BOOTSTRAP_PRIVATE_KEY" 2>/dev/null
        openssl ec -in "$BOOTSTRAP_PRIVATE_KEY" -pubout -out "$BOOTSTRAP_PUBLIC_KEY" 2>/dev/null
    fi
}

start_picod() {
    local cpu_limit=$1
    local encryption_enabled="${PICOD_ENCRYPTION_ENABLED:-false}"
    echo -e "${BLUE}🚀 Starting PicoD (CPUs: $cpu_limit, Port: $PICOD_PORT, Encryption: $encryption_enabled, ForceOctet: ${PICOD_FORCE_OCTET_STREAM:-false})...${NC}"
    
    cleanup # Ensure clean slate

    if [[ "$OSTYPE" == "darwin"* ]]; then
        PUBLIC_KEY_B64=$(base64 -i "$BOOTSTRAP_PUBLIC_KEY")
    else
        PUBLIC_KEY_B64=$(base64 -w 0 "$BOOTSTRAP_PUBLIC_KEY")
    fi

    docker run -d \
        --name "$CONTAINER_NAME" \
        --cpus="$cpu_limit" \
        -p "$PICOD_PORT:$PICOD_PORT" \
        -e PICOD_PORT="$PICOD_PORT" \
        -e PICOD_FORCE_OCTET_STREAM="${PICOD_FORCE_OCTET_STREAM:-false}" \
        -e PICOD_ENCRYPTION_ENABLED="$encryption_enabled" \
        -e PICOD_AUTH_MODE=static \
        -e PICOD_PUBLIC_KEY="$PUBLIC_KEY_B64" \
        "$PICOD_IMAGE" >/dev/null

    # Wait for health
    for i in {1..30}; do
        if curl -s "http://localhost:$PICOD_PORT/health" >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done
    echo -e "${RED}❌ PicoD failed to start${NC}"
    docker logs "$CONTAINER_NAME"
    exit 1
}

run_test_scenario() {
    local cpu=$1
    local conc=$2
    local encryption_flag=""
    if [ "${PICOD_ENCRYPTION_ENABLED:-false}" == "true" ]; then
        encryption_flag="--encryption"
    fi
    
    echo -e "${YELLOW}👉 Running Scenario: CPU=$cpu, Concurrency=$conc, Encryption=${PICOD_ENCRYPTION_ENABLED:-false}${NC}"
    
    # Run the python test script
    # We pass the same output csv file to accumulate results
    if TEST_FORCE_OCTET="${PICOD_FORCE_OCTET_STREAM:-false}" python3 test_picod.py \
        --url "http://localhost:$PICOD_PORT" \
        --key "$BOOTSTRAP_PRIVATE_KEY" \
        --concurrency "$conc" \
        --cpu-limit "$cpu" \
        --output-csv "$OUTPUT_CSV" \
        --mode "concurrent" \
        $encryption_flag; then
            echo -e "${GREEN}✅ Scenario passed${NC}"
    else
            echo -e "${RED}❌ Scenario failed${NC}"
            # Don't exit immediately, try next scenario? 
            # Requirement says "test multiple dimensions", usually we want all data.
            # But if functional test fails, maybe stop.
    fi
}

main() {
    trap cleanup EXIT
    
    echo -e "${BLUE}🧪 PicoD Benchmark Suite${NC}"
    echo "Results will be saved to: $OUTPUT_CSV"
    
    generate_keys
    
    # Check dependencies
    if ! pip3 show requests cryptography pyjwt >/dev/null 2>&1; then
        echo "Installing Python dependencies..."
        pip3 install -q requests cryptography pyjwt
    fi

    local encryption_flag=""
    if [ "${PICOD_ENCRYPTION_ENABLED:-false}" == "true" ]; then
        encryption_flag="--encryption"
    fi

    # 1. Run Functional Sanity Check (Single point)
    # run with 1.0 cpu and 1 concurrency just to verify image works
    start_picod "1.0"
    echo -e "${BLUE}Running Functional Sanity Check...${NC}"
    if TEST_FORCE_OCTET="${PICOD_FORCE_OCTET_STREAM:-false}" python3 test_picod.py \
        --url "http://localhost:$PICOD_PORT" \
        --key "$BOOTSTRAP_PRIVATE_KEY" \
        --concurrency 1 \
        --cpu-limit "1.0" \
        --output-csv "$OUTPUT_CSV" \
        --mode "functional" \
        $encryption_flag; then
        echo -e "${GREEN}✅ Functional check passed${NC}"
    else
        echo -e "${RED}❌ Functional check failed${NC}"
        exit 1
    fi
    cleanup

    # 2. Run Benchmark Matrix
    for cpu in "${CPU_LIMITS[@]}"; do
        # Start container once per CPU config to save time?
        # Or restart for every concurrency to ensure clean state?
        # Restarting is safer for memory leak detection/clean state.
        
        for conc in "${CONCURRENCIES[@]}"; do
            start_picod "$cpu"
            run_test_scenario "$cpu" "$conc"
            cleanup
        done
    done
    
    echo -e "\n${GREEN}🎉 All tests completed.${NC}"
    echo "Report generated at: $OUTPUT_CSV"
}

main "$@"