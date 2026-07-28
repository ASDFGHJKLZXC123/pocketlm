#!/usr/bin/env bash

# Shared, dependency-free disk-space checks for model fetch and Simulator seed.
# Callers use set -euo pipefail before sourcing this file.

POCKETLM_MIN_FREE_BYTES_DEFAULT=$((64 * 1024 * 1024))

pocketlm_available_bytes() {
    local path="$1"
    local available

    available=$(df -Pk "$path" | awk 'NR == 2 { printf "%.0f\n", $4 * 1024 }')
    if [[ ! "$available" =~ ^[0-9]+$ ]]; then
        echo "Unable to determine available disk space for: $path" >&2
        return 1
    fi
    echo "$available"
}

pocketlm_require_free_space() {
    local path="$1"
    local payload_bytes="$2"
    local purpose="$3"
    local reserve_bytes="${POCKETLM_MIN_FREE_BYTES:-$POCKETLM_MIN_FREE_BYTES_DEFAULT}"
    local available_bytes
    local required_bytes

    if [[ ! "$payload_bytes" =~ ^[0-9]+$ ]] || [[ ! "$reserve_bytes" =~ ^[0-9]+$ ]]; then
        echo "Disk-space inputs must be nonnegative integers." >&2
        return 1
    fi

    available_bytes=$(pocketlm_available_bytes "$path")
    required_bytes=$((payload_bytes + reserve_bytes))
    if (( available_bytes < required_bytes )); then
        echo "Insufficient disk space for $purpose: need $required_bytes bytes " \
             "($payload_bytes payload + $reserve_bytes reserve), have $available_bytes." >&2
        return 1
    fi

    echo "Disk check passed for $purpose: $available_bytes bytes available; " \
         "$required_bytes required."
}
