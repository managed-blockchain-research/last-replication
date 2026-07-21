#!/bin/bash

# E-Spill Baseline Test Orchestration Script
# Runs all three intensity levels and collects comprehensive metrics

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "${SCRIPT_DIR}")"
RESULTS_DIR="${PROJECT_DIR}/results"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# Test configurations
TESTS=("low" "medium" "high")
declare -A TEST_DURATIONS=(
    ["low"]="300"
    ["medium"]="600"
    ["high"]="900"
)

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo "======================================================================"
echo "E-SPILL BASELINE TEST SUITE"
echo "======================================================================"
echo "Timestamp: ${TIMESTAMP}"
echo "Results Directory: ${RESULTS_DIR}"
echo ""

# Parse command line arguments
RUN_ONLY=""
if [ "$1" == "--only" ] && [ -n "$2" ]; then
    RUN_ONLY="$2"
    echo "Running only: ${RUN_ONLY} intensity test"
    TESTS=("${RUN_ONLY}")
fi

# Function to check if Besu is running
check_besu_running() {
    if ! pgrep -f "besu.*--network=dev" > /dev/null; then
        return 1
    fi
    return 0
}

# Function to wait for Besu to be ready
wait_for_besu() {
    echo -n "Waiting for Besu to be ready..."
    MAX_WAIT=60
    COUNT=0
    while [ ${COUNT} -lt ${MAX_WAIT} ]; do
        if curl -s -X POST -H "Content-Type: application/json" \
            --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
            http://localhost:8545 > /dev/null 2>&1; then
            echo " Ready!"
            return 0
        fi
        echo -n "."
        sleep 1
        COUNT=$((COUNT + 1))
    done
    echo " Timeout!"
    return 1
}

# Function to deploy StateBloater contract
deploy_contract() {
    echo "Deploying StateBloater contract..."
    
    # Check if contract is already deployed
    if grep -q "0x" "${PROJECT_DIR}/networkconfig.json" 2>/dev/null; then
        EXISTING_ADDR=$(grep -o '"address":\s*"0x[^"]*"' "${PROJECT_DIR}/networkconfig.json" | cut -d'"' -f4)
        if [ "${EXISTING_ADDR}" != "PASTE_THE_0x_ADDRESS_HERE" ]; then
            echo "Contract already deployed at: ${EXISTING_ADDR}"
            return 0
        fi
    fi
    
    # Deploy using web3 or manual deployment script
    # For now, check if manual_deploy.js exists
    if [ -f "${PROJECT_DIR}/manual_deploy.js" ]; then
        cd "${PROJECT_DIR}"
        node manual_deploy.js
        echo "✓ Contract deployed"
    else
        echo "⚠️  WARNING: manual_deploy.js not found"
        echo "   You may need to manually deploy the StateBloater contract"
        echo "   Press Enter to continue or Ctrl+C to abort"
        read
    fi
}

# Function to run a single test
run_test() {
    local intensity=$1
    local test_dir="${RESULTS_DIR}/${intensity}_intensity"
    local gc_log_dir="${test_dir}/gc_logs"
    local caliper_dir="${test_dir}/caliper_reports"
    
    echo ""
    echo "======================================================================"
    echo "RUNNING ${intensity^^} INTENSITY TEST"
    echo "======================================================================"
    
    # Create directories
    mkdir -p "${gc_log_dir}" "${caliper_dir}"
    
    # Stop Besu if running
    echo "Stopping any existing Besu instances..."
    "${SCRIPT_DIR}/stop_besu.sh" || true
    sleep 3
    
    # Clear old data for clean test
    echo "Cleaning data directory for fresh test..."
    rm -rf "${PROJECT_DIR}/data_bl"/*
    
    # Start Besu with GC logging
    echo "Starting Besu with GC logging..."
    "${SCRIPT_DIR}/start_besu_baseline.sh"
    
    if ! check_besu_running; then
        echo "${RED}ERROR: Failed to start Besu${NC}"
        exit 1
    fi
    
    # Wait for Besu to be ready
    if ! wait_for_besu; then
        echo "${RED}ERROR: Besu did not become ready${NC}"
        exit 1
    fi
    
    # Deploy contract if needed
    deploy_contract
    
    # Give Besu a moment to stabilize
    echo "Allowing Besu to stabilize (10 seconds)..."
    sleep 10
    
    # Run Caliper benchmark
    echo ""
    echo "Starting Caliper benchmark (${intensity} intensity)..."
    echo "Expected duration: ~${TEST_DURATIONS[$intensity]} seconds"
    echo ""
    
    cd "${PROJECT_DIR}"
    
    local bench_config="benchconfig-${intensity}.yaml"
    if [ ! -f "${bench_config}" ]; then
        echo "${RED}ERROR: Benchmark config not found: ${bench_config}${NC}"
        exit 1
    fi
    
    # Run Caliper
    echo "Command: npx caliper launch manager --caliper-workspace ./ --caliper-benchconfig ${bench_config} --caliper-networkconfig networkconfig.json"
    
    npx caliper launch manager \
        --caliper-workspace ./ \
        --caliper-benchconfig "${bench_config}" \
        --caliper-networkconfig networkconfig.json \
        2>&1 | tee "${caliper_dir}/caliper_console_${TIMESTAMP}.log"
    
    echo ""
    echo "${GREEN}✓ Benchmark completed${NC}"
    
    # Copy results
    echo "Collecting results..."
    
    # Copy GC logs
    cp baseline_gc_*.log "${gc_log_dir}/" 2>/dev/null || echo "No GC logs found (may still be writing)"
    
    # Copy Caliper reports
    cp report.html "${caliper_dir}/report_${TIMESTAMP}.html" 2>/dev/null || echo "No HTML report"
    cp caliper.log "${caliper_dir}/caliper_${TIMESTAMP}.log" 2>/dev/null || echo "No Caliper log"
    
    # Copy Besu console logs
    cp "${PROJECT_DIR}/data_bl/besu_console.log" "${test_dir}/besu_console_${TIMESTAMP}.log" 2>/dev/null || true
    
    # Analyze GC logs
    echo ""
    echo "Analyzing GC logs..."
    LATEST_GC_LOG=$(ls -t baseline_gc_*.log 2>/dev/null | head -1)
    if [ -n "${LATEST_GC_LOG}" ]; then
        python3 "${SCRIPT_DIR}/monitor_gc.py" "${LATEST_GC_LOG}" "${test_dir}/gc_events.csv"
        echo ""
    fi
    
    # Analyze latency
    echo "Analyzing transaction latency..."
    if [ -f "${caliper_dir}/report_${TIMESTAMP}.html" ]; then
        python3 "${SCRIPT_DIR}/monitor_latency.py" "${caliper_dir}/report_${TIMESTAMP}.html" "${test_dir}/latency.csv"
    else
        echo "⚠️  No report file found for latency analysis"
    fi
    
    echo ""
    echo "${GREEN}✓ ${intensity^^} intensity test completed${NC}"
    echo "Results saved to: ${test_dir}"
    echo ""
}

# Main test execution
for test in "${TESTS[@]}"; do
    run_test "${test}"
    
    # Pause between tests
    if [ "${test}" != "${TESTS[-1]}" ]; then
        echo ""
        echo "Pausing 30 seconds before next test..."
        sleep 30
    fi
done

# Stop Besu after all tests
echo ""
echo "Stopping Besu..."
"${SCRIPT_DIR}/stop_besu.sh"

echo ""
echo "======================================================================"
echo "ALL BASELINE TESTS COMPLETED"
echo "======================================================================"
echo "Results directory: ${RESULTS_DIR}"
echo ""
echo "Next steps:"
echo "  1. Review results in ${RESULTS_DIR}"
echo "  2. Run analysis: python3 scripts/analyze_baseline.py"
echo "  3. Generate report: python3 scripts/generate_baseline_report.py"
echo ""
