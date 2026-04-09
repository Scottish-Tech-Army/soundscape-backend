#!/bin/bash
# Script to run tests on the Photon geocoding API
set -euo pipefail

DNS_SUFFIX=soundscape.scottishtecharmy.org

# This script should be run from the location where the outputs are to go
# This file takes a single argument, which specifies the domain to test
if [[ $# -ne 1 ]]; then
    echo "Usage: $0 {photon|photontest|legacy}"
    exit 1
fi

case "$1" in
    photon)
        DOMAIN="$1"
        PHOTON_BASE_URL="https://photon.${DNS_SUFFIX}/photon"
        ;;
    photontest)
        DOMAIN="$1"
        PHOTON_BASE_URL="https://photontest.${DNS_SUFFIX}/photon"
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
echo "timestamp,test_name,status,x_cache,details" > "${CSVFILE}"

# Initialize counters
PASS_COUNT=0
FAIL_COUNT=0

# Helper function to randomize case of a string
randomize_case() {
    local input="$1"
    local output=""
    local char
    for ((i=0; i<${#input}; i++)); do
        char="${input:$i:1}"
        if [[ "$((RANDOM % 2))" -eq 0 ]]; then
            output+="${char,,}"  # lowercase
        else
            output+="${char^^}"  # uppercase
        fi
    done
    echo "$output"
}

# Helper function to URL-encode a string
url_encode() {
    local string="$1"
    local strlen=${#string}
    local encoded=""
    local pos c o

    for ((pos=0; pos<strlen; pos++)); do
        c=${string:$pos:1}
        case "$c" in
            [-_.~a-zA-Z0-9])
                o="${c}"
                ;;
            *)
                printf -v o '%%%02x' "'$c"
                ;;
        esac
        encoded+="${o}"
    done
    echo "${encoded}"
}

# Helper function to log results
log_result() {
    local test_name="$1"
    local status="$2"
    local x_cache="$3"
    local details="$4"
    local timestamp=$(date +%Y-%m-%d\ %H:%M:%S)

    echo "[${timestamp}] ${test_name}: ${status} [x-cache: ${x_cache}] - ${details}" | tee -a "${LOGFILE}"
    echo "\"${timestamp}\",\"${test_name}\",\"${status}\",\"${x_cache}\",\"${details}\"" >> "${CSVFILE}"

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
    echo "  URL: ${url}" | tee -a "${LOGFILE}"

    # Make the request and capture headers
    local temp_headers=$(mktemp)
    local response
    local http_code
    response=$(curl -s -D "${temp_headers}" -w "\n%{http_code}" "${url}")
    http_code=$(echo "${response}" | tail -n1)
    local body=$(echo "${response}" | sed '$d')

    # Extract x-cache header
    local x_cache=$(grep -i "^x-cache:" "${temp_headers}" | sed 's/^x-cache: *//i' | tr -d '\r\n' || echo "N/A")
    rm -f "${temp_headers}"

    # Check HTTP status
    if [[ "${http_code}" != "200" ]]; then
        log_result "${test_name}" "FAIL" "${x_cache}" "HTTP ${http_code}"
        return 1
    fi

    # Run validation if provided
    if [[ -n "${validation_cmd}" ]]; then
        local validation_result
        if validation_result=$(echo "${body}" | eval "${validation_cmd}" 2>&1); then
            log_result "${test_name}" "PASS" "${x_cache}" "Validation succeeded: ${validation_result}"
            return 0
        else
            log_result "${test_name}" "FAIL" "${x_cache}" "Validation failed: ${validation_result}"
            echo "Response body received:" | tee -a "${LOGFILE}"
            echo "${body}" | tee -a "${LOGFILE}"
            echo "" | tee -a "${LOGFILE}"
            return 1
        fi
    else
        log_result "${test_name}" "PASS" "${x_cache}" "HTTP 200"
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
QUERY1=$(randomize_case "Tower of London")
QUERY1_ENCODED=$(url_encode "${QUERY1}")
run_test \
    "Forward geocoding: Tower of London" \
    "${PHOTON_BASE_URL}/api?q=${QUERY1_ENCODED}" \
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
QUERY5=$(randomize_case "Tokyo")
QUERY5_ENCODED=$(url_encode "${QUERY5}")
run_test \
    "Forward geocoding: Tokyo (Japanese)" \
    "${PHOTON_BASE_URL}/api?q=${QUERY5_ENCODED}" \
    "jq -r '.features[0].properties.name' | grep '東京'" || true

# Test 6: Forward geocoding - Tokyo with English language
QUERY6=$(randomize_case "Tokyo")
QUERY6_ENCODED=$(url_encode "${QUERY6}")
run_test \
    "Forward geocoding: Tokyo (English)" \
    "${PHOTON_BASE_URL}/api?q=${QUERY6_ENCODED}&lang=en" \
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
