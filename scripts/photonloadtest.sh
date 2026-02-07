#!/bin/bash
# Script to run tests on the Photon geocoding API
set -euo pipefail

# This script should be run from the location where the outputs are to go
# This file takes a single argument, which specifies the domain to test
if [[ $# -ne 1 ]]; then
    echo "Usage: $0 {photon|photontest|legacy}"
    exit 1
fi

case "$1" in
    photon)
        DOMAIN="$1"
        PHOTON_BASE_URL="https://photon.soundscape.scottishtecharmy.org/photon"
        ;;
    photontest)
        DOMAIN="$1"
        PHOTON_BASE_URL="https://photontest.soundscape.scottishtecharmy.org/photon"
        ;;
    legacy)
        DOMAIN="$1"
        PHOTON_BASE_URL="https://ph.sta-assets.org"
        ;;
    *)
        echo "Invalid argument: $1 - must be one of photon, photontest, legacy"
        exit 1
        ;;
esac

export OUTDIR="$(pwd)/${DOMAIN}"
mkdir -p "${OUTDIR}"

LOGFILE="${OUTDIR}/${DOMAIN}_$(date +%Y%m%d_%H%M%S).log"
CSVFILE="${OUTDIR}/${DOMAIN}_$(date +%Y%m%d_%H%M%S).csv"

# Initialize CSV with header
echo "timestamp,test_name,status,details" > "${CSVFILE}"

# Initialize counters
PASS_COUNT=0
FAIL_COUNT=0

# Helper function to log results
log_result() {
    local test_name="$1"
    local status="$2"
    local details="$3"
    local timestamp=$(date +%Y-%m-%d\ %H:%M:%S)

    echo "[${timestamp}] ${test_name}: ${status} - ${details}" | tee -a "${LOGFILE}"
    echo "\"${timestamp}\",\"${test_name}\",\"${status}\",\"${details}\"" >> "${CSVFILE}"

    # Update counters
    if [[ "${status}" == "PASS" ]]; then
        PASS_COUNT=$((PASS_COUNT + 1))
    elif [[ "${status}" == "FAIL" ]]; then
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
}

# Helper function to run a test
run_test() {
    local test_name="$1"
    local url="$2"
    local validation_cmd="$3"

    echo "Running test: ${test_name}" | tee -a "${LOGFILE}"

    # Make the request
    local response
    local http_code
    response=$(curl -s -w "\n%{http_code}" "${url}")
    http_code=$(echo "${response}" | tail -n1)
    local body=$(echo "${response}" | sed '$d')

    # Check HTTP status
    if [[ "${http_code}" != "200" ]]; then
        log_result "${test_name}" "FAIL" "HTTP ${http_code}"
        return 1
    fi

    # Run validation if provided
    if [[ -n "${validation_cmd}" ]]; then
        local validation_result
        if validation_result=$(echo "${body}" | eval "${validation_cmd}" 2>&1); then
            log_result "${test_name}" "PASS" "Validation succeeded: ${validation_result}"
            return 0
        else
            log_result "${test_name}" "FAIL" "Validation failed: ${validation_result}"
            echo "Response body received:" | tee -a "${LOGFILE}"
            echo "${body}" | tee -a "${LOGFILE}"
            echo "" | tee -a "${LOGFILE}"
            return 1
        fi
    else
        log_result "${test_name}" "PASS" "HTTP 200"
        return 0
    fi
}

echo "Starting Photon API tests for ${DOMAIN}" | tee -a "${LOGFILE}"
echo "Base URL: ${PHOTON_BASE_URL}" | tee -a "${LOGFILE}"
echo "Output directory: ${OUTDIR}" | tee -a "${LOGFILE}"
echo "Log file: ${LOGFILE}" | tee -a "${LOGFILE}"
echo "CSV file: ${CSVFILE}" | tee -a "${LOGFILE}"
echo "" | tee -a "${LOGFILE}"

# Test 1: Forward geocoding - Tower of London
run_test \
    "Forward geocoding: Tower of London" \
    "${PHOTON_BASE_URL}/api?q=Tower%20of%20London" \
    "jq -r '.features[0].properties.postcode' | grep -E '^EC3N'" || true

# Test 2: Reverse geocoding - Tower of London coordinates
run_test \
    "Reverse geocoding: Tower of London coordinates" \
    "${PHOTON_BASE_URL}/reverse?lon=-0.0761879025700761&lat=51.508217" \
    "jq -r '.features[0].properties.name' | grep -i 'tower'" || true

# Test 3: Reverse geocoding with French language
run_test \
    "Reverse geocoding: French language" \
    "${PHOTON_BASE_URL}/reverse?lon=-0.0761879025700761&lat=51.508217&lang=fr" \
    "jq -r '.features[0].properties.country' | grep -E 'Royaume-Uni|Grande-Bretagne'" || true

# Test 4: Reverse geocoding with German language
run_test \
    "Reverse geocoding: German language" \
    "${PHOTON_BASE_URL}/reverse?lon=-0.0761879025700761&lat=51.508217&lang=de" \
    "jq -r '.features[0].properties.country' | grep -E 'Vereinigtes Königreich|Großbritannien'" || true

# Test 5: Forward geocoding - Tokyo (should return Japanese characters)
run_test \
    "Forward geocoding: Tokyo (Japanese)" \
    "${PHOTON_BASE_URL}/api?q=Tokyo" \
    "jq -r '.features[0].properties.name' | grep '東京'" || true

# Test 6: Forward geocoding - Tokyo with English language
run_test \
    "Forward geocoding: Tokyo (English)" \
    "${PHOTON_BASE_URL}/api?q=Tokyo&lang=en" \
    "jq -r '.features[0].properties.name' | grep -E '^Tokyo$|^Tōkyō$'" || true

echo "" | tee -a "${LOGFILE}"
echo "All tests completed" | tee -a "${LOGFILE}"
echo "Results written to:" | tee -a "${LOGFILE}"
echo "  Log: ${LOGFILE}" | tee -a "${LOGFILE}"
echo "  CSV: ${CSVFILE}" | tee -a "${LOGFILE}"
echo "" | tee -a "${LOGFILE}"
echo "Summary: ${PASS_COUNT} passed, ${FAIL_COUNT} failed" | tee -a "${LOGFILE}"

if [[ ${FAIL_COUNT} -gt 0 ]]; then
    exit 1
fi

exit 0
