#!/bin/bash
set -Eeuo pipefail

# =============================================================================
# Chronicler — Excalibur v4 SAM Log Export Utility
#
# Copyright (c) 2026 Excalibur s.r.o. All rights reserved.
#
# This script collects application logs from an Excalibur v4 SAM
# (Streamed Access Management) deployment by querying the embedded
# Loki log aggregation service. Logs are packaged into a compressed
# archive suitable for offline analysis or secure transfer to
# Excalibur support.
#
# Supported runtimes:
#   - Docker Compose deployments (default)
#   - Kubernetes / kubectl deployments
#
# Prerequisites:
#   - docker or kubectl available in PATH
#   - A running Excalibur v4 SAM stack with Loki enabled
#   - (optional) openssl for encrypted export
#
# Usage:
#   ./excalibur-chronicler.sh [OPTIONS]
#
# The exported JSON can be imported into any Loki/Grafana instance
# for analysis using the companion import-logs.sh script.
#
# https://github.com/excalibur-enterprise/excalibur-v4-chronicler
# =============================================================================

SCRIPT_NAME="$(basename -- "${BASH_SOURCE[0]}")"

# -----------------------------------------------------------------------------
# Defaults
# -----------------------------------------------------------------------------
SINCE="2h"
SINCE_SET=false
SINCE_SECONDS=0
DATE_FROM=""
DATE_TO=""
LEVEL=""
SERVICE=""
BATCH_SIZE=5000
OUTPUT_DIR="."
OUTPUT_FILE=""
LOKI_URL="http://loki:3100"
RUNTIME="docker"
CONTAINER=""
NAMESPACE="excalibur"
ENCRYPT=false
OPENSSL_LOCATION="host"
AUTO_CONFIRM=false
VERBOSE=false

# -----------------------------------------------------------------------------
# Logging (colors auto-disabled when stderr is not a terminal)
# -----------------------------------------------------------------------------
if [[ -t 2 ]]; then
    _C_RESET=$'\033[0m'
    _C_GREEN=$'\033[0;32m'
    _C_YELLOW=$'\033[0;33m'
    _C_RED=$'\033[0;31m'
    _C_CYAN=$'\033[0;36m'
else
    _C_RESET="" _C_GREEN="" _C_YELLOW="" _C_RED="" _C_CYAN=""
fi

log_info() {
    printf '%s[%s] INFO:%s %s\n' "$_C_GREEN" "$(date +'%Y-%m-%d %H:%M:%S')" "$_C_RESET" "$*" >&2
}

log_warn() {
    printf '%s[%s] WARN:%s %s\n' "$_C_YELLOW" "$(date +'%Y-%m-%d %H:%M:%S')" "$_C_RESET" "$*" >&2
}

log_error() {
    printf '%s[%s] ERROR:%s %s\n' "$_C_RED" "$(date +'%Y-%m-%d %H:%M:%S')" "$_C_RESET" "$*" >&2
}

log_debug() {
    if [[ "$VERBOSE" == "true" ]]; then
        printf '%s[%s] DEBUG:%s %s\n' "$_C_CYAN" "$(date +'%Y-%m-%d %H:%M:%S')" "$_C_RESET" "$*" >&2
    fi
}

# -----------------------------------------------------------------------------
# Usage
# -----------------------------------------------------------------------------
usage() {
    cat <<EOF
Usage: $SCRIPT_NAME [OPTIONS]

Export Excalibur application logs from Loki for support analysis.

Options:
    -t, --since DURATION  Time range to export: e.g. 30m, 6h, 2d, 1w (default: 2h, max: 30d)
        --from DATETIME   Start of date range (ISO 8601: 2026-03-20 or 2026-03-20T14:00:00)
        --to DATETIME     End of date range (default: now). Requires --from
    -l, --level LEVEL     Filter by log level: error, warn, info, debug (default: all)
    -s, --service NAME    Filter by service name, e.g. api, core, repository (default: all)
    -o, --output DIR      Output directory (default: current directory)
    -f, --file NAME       Output archive name (default: excalibur-logs-<timestamp>.tar.gz)
    -e, --encrypt         Encrypt output with Excalibur support public key (requires openssl)
    -r, --runtime RT      Container runtime: docker or kubectl (default: docker)
    -C, --container NAME  Specific container/pod name to exec into (auto-detected if omitted)
    -N, --namespace NS    Kubernetes namespace (default: excalibur, ignored for docker)
        --loki-url URL    Loki URL inside the container network (default: http://loki:3100)
        --batch-size N    Number of log entries per paginated request (default: 5000)
    -y, --yes             Skip confirmation prompt
    -v, --verbose         Enable verbose output
    -h, --help            Show this help message

Examples:
    # Export last 2h of all logs (docker)
    $SCRIPT_NAME

    # Export last 6h of errors only
    $SCRIPT_NAME --since 6h --level error

    # Export last 30 minutes
    $SCRIPT_NAME --since 30m

    # Export last 2 days
    $SCRIPT_NAME --since 2d

    # Export encrypted for secure transfer to support
    $SCRIPT_NAME --since 6h --encrypt

    # Export core service logs
    $SCRIPT_NAME --service core

    # Export specific date range
    $SCRIPT_NAME --from 2026-03-20 --to 2026-03-22

    # Export from a specific date until now
    $SCRIPT_NAME --from 2026-03-25T14:00:00

    # Export from Kubernetes deployment
    $SCRIPT_NAME --runtime kubectl --namespace excalibur

    # Export last 1 week with custom output path
    $SCRIPT_NAME --since 1w --output /tmp

    # Use a smaller batch size to avoid Loki timeouts
    $SCRIPT_NAME --since 6h --batch-size 1000
EOF
    exit "${1:-0}"
}

# -----------------------------------------------------------------------------
# Argument parsing
# -----------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        -t|--since)
            [[ $# -ge 2 ]] || { log_error "--since requires a value"; usage 1; }
            SINCE="$2"
            SINCE_SET=true
            shift 2
            ;;
        --from)
            [[ $# -ge 2 ]] || { log_error "--from requires a value"; usage 1; }
            DATE_FROM="$2"
            shift 2
            ;;
        --to)
            [[ $# -ge 2 ]] || { log_error "--to requires a value"; usage 1; }
            DATE_TO="$2"
            shift 2
            ;;
        -l|--level)
            [[ $# -ge 2 ]] || { log_error "--level requires a value"; usage 1; }
            LEVEL="$2"
            shift 2
            ;;
        -s|--service)
            [[ $# -ge 2 ]] || { log_error "--service requires a value"; usage 1; }
            SERVICE="$2"
            shift 2
            ;;
        -o|--output)
            [[ $# -ge 2 ]] || { log_error "--output requires a value"; usage 1; }
            OUTPUT_DIR="$2"
            shift 2
            ;;
        -f|--file)
            [[ $# -ge 2 ]] || { log_error "--file requires a value"; usage 1; }
            OUTPUT_FILE="$2"
            shift 2
            ;;
        -e|--encrypt)
            ENCRYPT=true
            shift
            ;;
        -r|--runtime)
            [[ $# -ge 2 ]] || { log_error "--runtime requires a value"; usage 1; }
            RUNTIME="$2"
            shift 2
            ;;
        -C|--container)
            [[ $# -ge 2 ]] || { log_error "--container requires a value"; usage 1; }
            CONTAINER="$2"
            shift 2
            ;;
        -N|--namespace)
            [[ $# -ge 2 ]] || { log_error "--namespace requires a value"; usage 1; }
            NAMESPACE="$2"
            shift 2
            ;;
        --loki-url)
            [[ $# -ge 2 ]] || { log_error "--loki-url requires a value"; usage 1; }
            LOKI_URL="$2"
            shift 2
            ;;
        --batch-size)
            [[ $# -ge 2 ]] || { log_error "--batch-size requires a value"; usage 1; }
            if ! [[ "$2" =~ ^[0-9]+$ ]] || [[ "$2" -le 0 ]]; then
                log_error "--batch-size must be a positive integer"
                exit 1
            fi
            BATCH_SIZE="$2"
            if [[ "$BATCH_SIZE" -lt 100 ]]; then
                log_warn "Batch size ${BATCH_SIZE} is very low; exports may be slow"
            elif [[ "$BATCH_SIZE" -gt 50000 ]]; then
                log_warn "Batch size ${BATCH_SIZE} is very high; Loki may timeout on large batches"
            fi
            shift 2
            ;;
        -v|--verbose)
            VERBOSE=true
            shift
            ;;
        -y|--yes)
            AUTO_CONFIRM=true
            shift
            ;;
        -h|--help)
            usage 0
            ;;
        --)
            shift
            break
            ;;
        *)
            log_error "Unknown option: $1"
            usage 1
            ;;
    esac
done

# -----------------------------------------------------------------------------
# Parse duration string (e.g. 30m, 6h, 2d, 1w) into seconds
# -----------------------------------------------------------------------------
parse_duration() {
    local -r input="$1"
    local number unit

    if ! [[ "$input" =~ ^([0-9]+)([mhdw])$ ]]; then
        log_error "Invalid duration format: '$input'"
        log_error "Expected: <number><unit> where unit is m(inutes), h(ours), d(ays), w(eeks)"
        log_error "Examples: 30m, 6h, 2d, 1w"
        exit 1
    fi

    number="${BASH_REMATCH[1]}"
    unit="${BASH_REMATCH[2]}"

    case "$unit" in
        m) printf '%s' $((number * 60)) ;;
        h) printf '%s' $((number * 3600)) ;;
        d) printf '%s' $((number * 86400)) ;;
        w) printf '%s' $((number * 604800)) ;;
    esac
}

# -----------------------------------------------------------------------------
# Input validation
# -----------------------------------------------------------------------------
validate_inputs() {
    # Check for conflicting time options
    if [[ "$SINCE_SET" == "true" ]] && [[ -n "$DATE_FROM" || -n "$DATE_TO" ]]; then
        log_error "--since cannot be combined with --from/--to"
        exit 1
    fi

    if [[ -n "$DATE_TO" ]] && [[ -z "$DATE_FROM" ]]; then
        log_error "--to requires --from"
        exit 1
    fi

    if [[ -n "$DATE_FROM" ]]; then
        # Validate --from date
        if ! date -d "$DATE_FROM" +%s &>/dev/null; then
            log_error "Invalid --from date: '$DATE_FROM'"
            log_error "Expected ISO 8601 format: 2026-03-20 or 2026-03-20T14:00:00"
            exit 1
        fi

        # Validate --to date if provided
        if [[ -n "$DATE_TO" ]]; then
            if ! date -d "$DATE_TO" +%s &>/dev/null; then
                log_error "Invalid --to date: '$DATE_TO'"
                log_error "Expected ISO 8601 format: 2026-03-22 or 2026-03-22T23:59:59"
                exit 1
            fi

            local from_epoch to_epoch
            from_epoch=$(date -d "$DATE_FROM" +%s)
            to_epoch=$(date -d "$DATE_TO" +%s)
            if [[ "$from_epoch" -ge "$to_epoch" ]]; then
                log_error "--from must be before --to"
                exit 1
            fi
        fi
    else
        # Parse and validate --since duration
        SINCE_SECONDS=$(parse_duration "$SINCE")

        local -r max_seconds=$((30 * 86400))  # 30 days in seconds
        if [[ "$SINCE_SECONDS" -lt 60 ]] || [[ "$SINCE_SECONDS" -gt "$max_seconds" ]]; then
            log_error "--since must be between 1m and 30d (got: $SINCE)"
            exit 1
        fi
    fi

    # Validate level if set
    if [[ -n "$LEVEL" ]]; then
        case "$LEVEL" in
            error|warn|info|debug) ;;
            *)
                log_error "--level must be one of: error, warn, info, debug"
                exit 1
                ;;
        esac
    fi

    # Validate runtime
    case "$RUNTIME" in
        docker|kubectl) ;;
        *)
            log_error "--runtime must be 'docker' or 'kubectl'"
            exit 1
            ;;
    esac

    # Validate output directory
    if [[ ! -d "$OUTPUT_DIR" ]]; then
        log_error "Output directory does not exist: $OUTPUT_DIR"
        exit 1
    fi

    # Validate runtime tool is available
    if ! command -v "$RUNTIME" &>/dev/null; then
        log_error "'$RUNTIME' is not installed or not in PATH"
        exit 1
    fi

    # Sanitize service name (alphanumeric, hyphens, underscores only)
    if [[ -n "$SERVICE" ]] && ! [[ "$SERVICE" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        log_error "--service contains invalid characters (allowed: a-z, 0-9, -, _)"
        exit 1
    fi

    # Validate openssl is available when encryption is requested (host or container)
    if [[ "$ENCRYPT" == "true" ]]; then
        if command -v openssl &>/dev/null; then
            OPENSSL_LOCATION="host"
        else
            # openssl is pre-installed in the api container — will use it there
            OPENSSL_LOCATION="container"
            log_info "openssl not found on host, will use openssl from api container"
        fi
    fi
}

# -----------------------------------------------------------------------------
# Container detection
# -----------------------------------------------------------------------------
detect_container() {
    if [[ -n "$CONTAINER" ]]; then
        log_debug "Using specified container: $CONTAINER"
        return 0
    fi

    log_info "Auto-detecting api container (has curl + openssl)..."

    if [[ "$RUNTIME" == "docker" ]]; then
        # Match the api container by exact name
        CONTAINER=$(docker ps --filter "name=^api$" --format '{{.Names}}' | head -1) || true

        if [[ -z "$CONTAINER" ]]; then
            # Fallback: try substring match in case of prefixed names (e.g. excalibur-api-1)
            CONTAINER=$(docker ps --filter "name=api" --format '{{.Names}}' | grep -E '(^|[-_])api([-_]|$)' | head -1) || true
        fi
    else
        # kubectl: find the api pod
        CONTAINER=$(kubectl -n "$NAMESPACE" get pods \
            -l app=api \
            --field-selector=status.phase=Running \
            -o jsonpath='{.items[0].metadata.name}' 2>/dev/null) || true
    fi

    if [[ -z "$CONTAINER" ]]; then
        log_error "Cannot find the 'api' container/pod. Is the Excalibur stack running?"
        log_error "  Docker:  docker ps | grep api"
        log_error "  K8s:     kubectl -n $NAMESPACE get pods -l app=api"
        log_error ""
        log_error "You can specify the container manually with --container <name>"
        exit 1
    fi

    log_info "Using container: $CONTAINER"
}

# -----------------------------------------------------------------------------
# Build LogQL query
# -----------------------------------------------------------------------------
build_query() {
    local query='{product="excalibur-v4"'

    if [[ -n "$LEVEL" ]]; then
        query="${query}, level=\"${LEVEL}\""
    fi

    if [[ -n "$SERVICE" ]]; then
        query="${query}, appName=\"${SERVICE}\""
    fi

    query="${query}}"

    printf '%s' "$query"
}

# -----------------------------------------------------------------------------
# Execute curl inside container
# -----------------------------------------------------------------------------
exec_curl() {
    local -r start_ns="$1"
    local -r end_ns="$2"
    local -r query="$3"
    local -r batch="$4"

    if [[ "$RUNTIME" == "docker" ]]; then
        docker exec "$CONTAINER" \
            curl -sf -G "${LOKI_URL}/loki/api/v1/query_range" \
                --data-urlencode "query=${query}" \
                --data-urlencode "start=${start_ns}" \
                --data-urlencode "end=${end_ns}" \
                --data-urlencode "limit=${batch}" \
                --data-urlencode "direction=forward" \
                --max-time 120
    else
        kubectl -n "$NAMESPACE" exec "$CONTAINER" -- \
            curl -sf -G "${LOKI_URL}/loki/api/v1/query_range" \
                --data-urlencode "query=${query}" \
                --data-urlencode "start=${start_ns}" \
                --data-urlencode "end=${end_ns}" \
                --data-urlencode "limit=${batch}" \
                --data-urlencode "direction=forward" \
                --max-time 120
    fi
}

# -----------------------------------------------------------------------------
# Count log entries in a Loki JSON response (without jq)
# Counts occurrences of timestamp-value pairs: ["<nanoseconds>","<log line>"]
# -----------------------------------------------------------------------------
count_entries() {
    grep -oE '\["[0-9]+","' "$1" | wc -l
}

# -----------------------------------------------------------------------------
# Extract the latest nanosecond timestamp from a Loki JSON response
# Returns the highest timestamp found in ["<nanoseconds>","..."] pairs
# -----------------------------------------------------------------------------
get_last_timestamp() {
    grep -oE '\["[0-9]+",' "$1" | grep -oE '[0-9]+' | sort -n | tail -1
}

# -----------------------------------------------------------------------------
# Check Loki connectivity
# -----------------------------------------------------------------------------
check_loki() {
    log_info "Consulting the Oracle (Loki)..."

    local ready_response
    if [[ "$RUNTIME" == "docker" ]]; then
        ready_response=$(docker exec "$CONTAINER" \
            curl -sf "${LOKI_URL}/ready" --max-time 10 2>/dev/null) || true
    else
        ready_response=$(kubectl -n "$NAMESPACE" exec "$CONTAINER" -- \
            curl -sf "${LOKI_URL}/ready" --max-time 10 2>/dev/null) || true
    fi

    if [[ -z "$ready_response" ]]; then
        log_error "Cannot reach Loki at ${LOKI_URL}"
        log_error "Is the Loki service running? Check: docker ps | grep loki"
        exit 1
    fi

    log_info "The Oracle responds."

    # In verbose mode, query available labels for diagnostics
    if [[ "$VERBOSE" == "true" ]]; then
        local labels_response
        if [[ "$RUNTIME" == "docker" ]]; then
            labels_response=$(docker exec "$CONTAINER" \
                curl -sf "${LOKI_URL}/loki/api/v1/labels" --max-time 10 2>/dev/null) || true
        else
            labels_response=$(kubectl -n "$NAMESPACE" exec "$CONTAINER" -- \
                curl -sf "${LOKI_URL}/loki/api/v1/labels" --max-time 10 2>/dev/null) || true
        fi
        log_debug "Available labels: ${labels_response:-<none>}"
    fi
}

# -----------------------------------------------------------------------------
# Query log statistics using count_over_time / bytes_over_time instant queries
# -----------------------------------------------------------------------------
query_stats() {
    local -r start_ns="$1"
    local -r end_ns="$2"
    local -r query="$3"

    # Compute LogQL duration from nanosecond timestamps
    local duration_seconds=$(( (end_ns - start_ns) / 1000000000 ))
    if [[ "$duration_seconds" -lt 1 ]]; then
        duration_seconds=1
    fi
    local -r duration="${duration_seconds}s"

    # Query entry count via instant query
    local count_response
    if [[ "$RUNTIME" == "docker" ]]; then
        count_response=$(docker exec "$CONTAINER" \
            curl -sf -G "${LOKI_URL}/loki/api/v1/query" \
                --data-urlencode "query=sum(count_over_time(${query}[${duration}]))" \
                --data-urlencode "time=${end_ns}" \
                --max-time 60 2>/dev/null) || true
    else
        count_response=$(kubectl -n "$NAMESPACE" exec "$CONTAINER" -- \
            curl -sf -G "${LOKI_URL}/loki/api/v1/query" \
                --data-urlencode "query=sum(count_over_time(${query}[${duration}]))" \
                --data-urlencode "time=${end_ns}" \
                --max-time 60 2>/dev/null) || true
    fi

    log_debug "count_over_time response: ${count_response:-(empty)}"

    # Extract count: result is {"data":{"result":[{"value":[timestamp,"count"]}]}}
    local entries=0
    if [[ -n "$count_response" ]]; then
        entries=$(printf '%s' "$count_response" \
            | grep -oE '"value":\[[0-9.]+,"[0-9]+"' \
            | grep -oE '"[0-9]+"$' \
            | tr -d '"') || true
    fi

    # Query byte count via instant query
    local bytes_response
    if [[ "$RUNTIME" == "docker" ]]; then
        bytes_response=$(docker exec "$CONTAINER" \
            curl -sf -G "${LOKI_URL}/loki/api/v1/query" \
                --data-urlencode "query=sum(bytes_over_time(${query}[${duration}]))" \
                --data-urlencode "time=${end_ns}" \
                --max-time 60 2>/dev/null) || true
    else
        bytes_response=$(kubectl -n "$NAMESPACE" exec "$CONTAINER" -- \
            curl -sf -G "${LOKI_URL}/loki/api/v1/query" \
                --data-urlencode "query=sum(bytes_over_time(${query}[${duration}]))" \
                --data-urlencode "time=${end_ns}" \
                --max-time 60 2>/dev/null) || true
    fi

    log_debug "bytes_over_time response: ${bytes_response:-(empty)}"

    local bytes=0
    if [[ -n "$bytes_response" ]]; then
        bytes=$(printf '%s' "$bytes_response" \
            | grep -oE '"value":\[[0-9.]+,"[0-9]+"' \
            | grep -oE '"[0-9]+"$' \
            | tr -d '"') || true
    fi

    printf '%s %s' "${entries:-0}" "${bytes:-0}"
}

# -----------------------------------------------------------------------------
# Format byte count to human-readable
# -----------------------------------------------------------------------------
format_bytes() {
    local -r bytes="$1"
    if [[ "$bytes" -gt 1073741824 ]]; then
        printf '%s GB' "$((bytes / 1073741824))"
    elif [[ "$bytes" -gt 1048576 ]]; then
        printf '%s MB' "$((bytes / 1048576))"
    elif [[ "$bytes" -gt 1024 ]]; then
        printf '%s KB' "$((bytes / 1024))"
    else
        printf '%s bytes' "$bytes"
    fi
}

# -----------------------------------------------------------------------------
# Compute timestamps
# -----------------------------------------------------------------------------
compute_timestamps() {
    local start_epoch end_epoch

    if [[ -n "$DATE_FROM" ]]; then
        start_epoch=$(date -d "$DATE_FROM" -u +%s)
        if [[ -n "$DATE_TO" ]]; then
            end_epoch=$(date -d "$DATE_TO" -u +%s)
        else
            end_epoch=$(date -u +%s)
        fi
    else
        local -r seconds="$1"
        end_epoch=$(date -u +%s)
        start_epoch=$((end_epoch - seconds))
    fi

    # Loki expects nanosecond timestamps
    printf '%s %s' "${start_epoch}000000000" "${end_epoch}000000000"
}

# -----------------------------------------------------------------------------
# The Seal of Camelot — Excalibur support EC P-384 public key.
# Only Excalibur support holds the key to break this seal.
# -----------------------------------------------------------------------------
SUPPORT_PUBLIC_KEY=""
read -r -d '' SUPPORT_PUBLIC_KEY <<'PUBKEY' || true
-----BEGIN PUBLIC KEY-----
MHYwEAYHKoZIzj0CAQYFK4EEACIDYgAEWVcMx7PyDrnckFvEvkaUmqCDF2Esavyw
xpU/Jjw1g038lGpvvvbymr5MGiFNnW2assIIdKVRkKHFnsfdnz7joQ+kRvHQneXV
FVDHprs2ZrSzfbmj160NCPr09vgObyV4
-----END PUBLIC KEY-----
PUBKEY

# -----------------------------------------------------------------------------
# -----------------------------------------------------------------------------
# Encrypt file using ECDH envelope encryption (AES-256-CBC + EC P-384).
# Uses openssl on the host if available, otherwise runs inside the api container.
# -----------------------------------------------------------------------------
encrypt_file() {
    local -r input_file="$1"
    local -r pubkey_pem="$2"

    local work_dir
    work_dir=$(mktemp -d) || { log_error "Failed to create temp directory for encryption"; return 1; }

    local -r pubkey_file="${work_dir}/support-public.pem"
    local -r derived_key_file="${work_dir}/derived.key"
    local -r encrypted_data="${work_dir}/data.enc"
    local -r ephemeral_pub="${work_dir}/ephemeral.pub"
    local -r output_enc="${input_file}.enc.tar"

    printf '%s\n' "$pubkey_pem" > "$pubkey_file"

    if [[ "$OPENSSL_LOCATION" == "host" ]]; then
        _encrypt_on_host "$input_file" "$pubkey_file" "$derived_key_file" "$encrypted_data" "$ephemeral_pub" "$work_dir" \
            || { rm -rf "$work_dir"; return 1; }
    else
        _encrypt_in_container "$input_file" "$pubkey_file" "$encrypted_data" "$ephemeral_pub" "$work_dir" \
            || { rm -rf "$work_dir"; return 1; }
    fi

    # Package encrypted data + ephemeral public key
    tar cf "$output_enc" -C "$work_dir" data.enc ephemeral.pub \
        || { log_error "Failed to package encrypted files"; rm -rf "$work_dir"; return 1; }

    # Clean up temp files and original unencrypted file
    rm -rf "$work_dir"
    rm -f "$input_file"

    printf '%s' "$output_enc"
}

_encrypt_on_host() {
    local -r input_file="$1" pubkey_file="$2" derived_key_file="$3"
    local -r encrypted_data="$4" ephemeral_pub="$5" work_dir="$6"

    # Generate ephemeral EC key pair
    openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-384 \
        -out "${work_dir}/ephemeral.pem" 2>/dev/null \
        || { log_error "Failed to generate ephemeral key"; return 1; }

    openssl pkey -in "${work_dir}/ephemeral.pem" -pubout \
        -out "$ephemeral_pub" 2>/dev/null \
        || { log_error "Failed to extract ephemeral public key"; return 1; }

    # Derive shared secret via ECDH and hash it to get AES key
    openssl pkeyutl -derive \
        -inkey "${work_dir}/ephemeral.pem" \
        -peerkey "$pubkey_file" \
        -out "${work_dir}/shared.bin" \
        || { log_error "Failed to derive shared secret"; return 1; }

    openssl dgst -sha256 -binary "${work_dir}/shared.bin" > "$derived_key_file" \
        || { log_error "Failed to derive encryption key"; return 1; }

    # Encrypt data with AES-256-CBC
    openssl enc -aes-256-cbc -pbkdf2 -salt \
        -in "$input_file" \
        -out "$encrypted_data" \
        -pass file:"$derived_key_file" \
        || { log_error "Failed to encrypt data"; return 1; }

    # Clean up sensitive material
    rm -f "${work_dir}/ephemeral.pem" "${work_dir}/shared.bin" "$derived_key_file"
}

_encrypt_in_container() {
    local -r input_file="$1" pubkey_file="$2"
    local -r encrypted_data="$3" ephemeral_pub="$4" work_dir="$5"

    local -r ctmp="/tmp/exc-encrypt-$$"

    if [[ "$RUNTIME" == "docker" ]]; then
        docker exec "$CONTAINER" mkdir -p "$ctmp"
        docker cp "$input_file" "$CONTAINER:${ctmp}/input" \
            || { log_error "Failed to copy input file to container"; return 1; }
        docker cp "$pubkey_file" "$CONTAINER:${ctmp}/pubkey.pem" \
            || { log_error "Failed to copy public key to container"; return 1; }

        docker exec "$CONTAINER" sh -c "
            openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-384 \
                -out '${ctmp}/ephemeral.pem' 2>/dev/null &&
            openssl pkey -in '${ctmp}/ephemeral.pem' -pubout \
                -out '${ctmp}/ephemeral.pub' 2>/dev/null &&
            openssl pkeyutl -derive \
                -inkey '${ctmp}/ephemeral.pem' \
                -peerkey '${ctmp}/pubkey.pem' \
                -out '${ctmp}/shared.bin' &&
            openssl dgst -sha256 -binary '${ctmp}/shared.bin' > '${ctmp}/derived.key' &&
            openssl enc -aes-256-cbc -pbkdf2 -salt \
                -in '${ctmp}/input' \
                -out '${ctmp}/data.enc' \
                -pass file:'${ctmp}/derived.key' &&
            rm -f '${ctmp}/ephemeral.pem' '${ctmp}/shared.bin' '${ctmp}/derived.key'
        " || { log_error "Encryption failed inside container"; return 1; }

        docker cp "$CONTAINER:${ctmp}/data.enc" "$encrypted_data" \
            || { log_error "Failed to copy encrypted data from container"; return 1; }
        docker cp "$CONTAINER:${ctmp}/ephemeral.pub" "$ephemeral_pub" \
            || { log_error "Failed to copy ephemeral key from container"; return 1; }

        docker exec "$CONTAINER" rm -rf "$ctmp"

    elif [[ "$RUNTIME" == "kubectl" ]]; then
        kubectl exec "$CONTAINER" -n "$NAMESPACE" -- mkdir -p "$ctmp"
        kubectl cp "$input_file" "$NAMESPACE/$CONTAINER:${ctmp}/input" \
            || { log_error "Failed to copy input file to pod"; return 1; }
        kubectl cp "$pubkey_file" "$NAMESPACE/$CONTAINER:${ctmp}/pubkey.pem" \
            || { log_error "Failed to copy public key to pod"; return 1; }

        kubectl exec "$CONTAINER" -n "$NAMESPACE" -- sh -c "
            openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-384 \
                -out '${ctmp}/ephemeral.pem' 2>/dev/null &&
            openssl pkey -in '${ctmp}/ephemeral.pem' -pubout \
                -out '${ctmp}/ephemeral.pub' 2>/dev/null &&
            openssl pkeyutl -derive \
                -inkey '${ctmp}/ephemeral.pem' \
                -peerkey '${ctmp}/pubkey.pem' \
                -out '${ctmp}/shared.bin' &&
            openssl dgst -sha256 -binary '${ctmp}/shared.bin' > '${ctmp}/derived.key' &&
            openssl enc -aes-256-cbc -pbkdf2 -salt \
                -in '${ctmp}/input' \
                -out '${ctmp}/data.enc' \
                -pass file:'${ctmp}/derived.key' &&
            rm -f '${ctmp}/ephemeral.pem' '${ctmp}/shared.bin' '${ctmp}/derived.key'
        " || { log_error "Encryption failed inside pod"; return 1; }

        kubectl cp "$NAMESPACE/$CONTAINER:${ctmp}/data.enc" "$encrypted_data" \
            || { log_error "Failed to copy encrypted data from pod"; return 1; }
        kubectl cp "$NAMESPACE/$CONTAINER:${ctmp}/ephemeral.pub" "$ephemeral_pub" \
            || { log_error "Failed to copy ephemeral key from pod"; return 1; }

        kubectl exec "$CONTAINER" -n "$NAMESPACE" -- rm -rf "$ctmp"
    fi
}

# -----------------------------------------------------------------------------
# Generate output filename
# -----------------------------------------------------------------------------
generate_export_name() {
    local timestamp
    timestamp=$(date +'%Y%m%d-%H%M%S')

    local name="excalibur-chronicle-${timestamp}"

    if [[ -n "$SERVICE" ]]; then
        name="excalibur-chronicle-${SERVICE}-${timestamp}"
    fi

    if [[ -n "$LEVEL" ]]; then
        name="${name}-${LEVEL}"
    fi

    printf '%s' "$name"
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
main() {
    log_info "Chronicler — Excalibur Log Export"
    log_info "============================================"

    validate_inputs
    detect_container
    check_loki

    # Build query
    local query
    query=$(build_query)
    log_info "LogQL query: ${query}"
    if [[ -n "$DATE_FROM" ]]; then
        if [[ -n "$DATE_TO" ]]; then
            log_info "Time range: ${DATE_FROM} to ${DATE_TO}"
        else
            log_info "Time range: ${DATE_FROM} to now"
        fi
    else
        log_info "Time range: last ${SINCE}"
    fi

    # Compute timestamps on the host
    local timestamps start_ns end_ns
    timestamps=$(compute_timestamps "$SINCE_SECONDS")
    read -r start_ns end_ns <<< "$timestamps"
    log_debug "Start: ${start_ns} | End: ${end_ns}"

    # Query stats to show estimated export size
    log_info "Querying log statistics..."
    local stats_result est_entries est_bytes
    stats_result=$(query_stats "$start_ns" "$end_ns" "$query")
    read -r est_entries est_bytes <<< "$stats_result"

    if [[ "$est_entries" -eq 0 ]]; then
        log_warn "No log entries found for the specified time range and filters"
        log_warn "Check that services are pushing logs to Loki"
        exit 0
    fi

    local est_batches=$(( (est_entries + BATCH_SIZE - 1) / BATCH_SIZE ))
    local est_size
    est_size=$(format_bytes "$est_bytes")

    log_info ""
    log_info "Estimated export:"
    log_info "  Entries:  ${est_entries}"
    log_info "  Size:     ${est_size} (uncompressed)"
    log_info "  Batches:  ${est_batches} (${BATCH_SIZE} per batch)"
    log_info ""

    if [[ "$AUTO_CONFIRM" != "true" ]]; then
        if [[ -t 0 ]]; then
            printf '%s[%s] INFO:%s  Proceed with the chronicle? [Y/n] ' "$_C_GREEN" "$(date +'%Y-%m-%d %H:%M:%S')" "$_C_RESET" >&2
            local confirm
            read -r confirm
            case "${confirm:-y}" in
                [yY]|[yY][eE][sS]|"") ;;
                *)
                    log_info "Chronicle cancelled."
                    exit 0
                    ;;
            esac
        else
            log_info "Non-interactive mode detected, proceeding automatically"
        fi
    fi

    # Determine export name and create batch directory
    local export_name
    if [[ -n "$OUTPUT_FILE" ]]; then
        export_name="${OUTPUT_FILE%.tar.gz}"  # strip extension if given
        export_name="${export_name%.json}"    # strip .json too
    else
        export_name=$(generate_export_name)
    fi

    local -r tmp_dir=$(mktemp -d) || { log_error "Failed to create temp directory"; exit 1; }
    local -r batch_dir="${tmp_dir}/${export_name}"
    mkdir -p "$batch_dir"
    local -r archive_path="${OUTPUT_DIR}/${export_name}.tar.gz"

    # Export logs with automatic pagination
    log_info "Gathering the chronicles..."

    local current_start="$start_ns"
    local total_entries=0
    local page=0

    while true; do
        page=$((page + 1))
        local batch_file
        batch_file=$(printf '%s/batch-%04d.json' "$batch_dir" "$page")

        log_debug "Fetching page ${page} (from ${current_start})..."

        if ! exec_curl "$current_start" "$end_ns" "$query" "$BATCH_SIZE" > "$batch_file"; then
            log_error "Failed to query Loki on page ${page}. Possible causes:"
            log_error "  - Loki URL incorrect (try --loki-url)"
            log_error "  - Network issue between container and Loki"
            rm -rf "$tmp_dir"
            exit 1
        fi

        # Check for Loki error responses
        local head_content
        head_content=$(head -c 200 "$batch_file")
        if [[ "$head_content" == *'"status":"error"'* ]] || [[ "$head_content" == *'"error":'* ]]; then
            log_error "Loki returned an error:"
            head -c 500 "$batch_file" >&2
            printf '\n' >&2
            rm -rf "$tmp_dir"
            exit 1
        fi

        # Count entries in this batch
        local batch_entries
        batch_entries=$(count_entries "$batch_file")
        total_entries=$((total_entries + batch_entries))

        if [[ "$batch_entries" -gt 0 ]]; then
            log_info "Page ${page}: ${batch_entries} entries (total: ${total_entries})"
        else
            # Empty batch — remove the file
            rm -f "$batch_file"
        fi

        # Stop if we got fewer entries than batch size (last page)
        if [[ "$batch_entries" -lt "$BATCH_SIZE" ]]; then
            break
        fi

        # Advance start past the last timestamp (+1 nanosecond to avoid duplicates)
        local last_ts
        last_ts=$(get_last_timestamp "$batch_file")
        if [[ -z "$last_ts" ]]; then
            log_warn "Could not extract timestamp from response, stopping pagination"
            break
        fi
        current_start=$((last_ts + 1))
    done

    log_info "Fetched ${total_entries} log entries in ${page} page(s)"

    # Validate output
    if [[ "$total_entries" -eq 0 ]]; then
        log_warn "No log entries found for the specified time range and filters"
        rm -rf "$tmp_dir"
        exit 0
    fi

    # Package all batches into a compressed tar archive
    log_info "Packaging ${page} batch file(s) into archive..."
    tar czf "$archive_path" -C "$tmp_dir" "$export_name" \
        || { log_error "Failed to create archive"; rm -rf "$tmp_dir"; exit 1; }
    rm -rf "$tmp_dir"

    local output_path_final="$archive_path"

    # Encrypt if requested
    if [[ "$ENCRYPT" == "true" ]]; then
        if [[ "$SUPPORT_PUBLIC_KEY" == *"REPLACE_WITH"* ]]; then
            log_error "Support public key has not been configured in this script."
            log_error "Contact Excalibur support to obtain the public key."
            exit 1
        fi

        log_info "Sealing the chronicle with the Seal of Camelot..."
        output_path_final=$(encrypt_file "$output_path_final" "$SUPPORT_PUBLIC_KEY")
        log_info "Sealed with enchantment — only Excalibur support holds the key."
    fi

    # Summary
    local final_size
    final_size=$(stat -c%s "$output_path_final" 2>/dev/null || stat -f%z "$output_path_final" 2>/dev/null || echo "unknown")
    local human_size
    if [[ "$final_size" =~ ^[0-9]+$ ]]; then
        if [[ "$final_size" -gt 1048576 ]]; then
            human_size="$((final_size / 1048576)) MB"
        elif [[ "$final_size" -gt 1024 ]]; then
            human_size="$((final_size / 1024)) KB"
        else
            human_size="${final_size} bytes"
        fi
    else
        human_size="unknown"
    fi

    log_info "============================================"
    log_info "The chronicle is complete."
    log_info "File: ${output_path_final}"
    log_info "Size: ${human_size}"
    log_info ""
    log_info "Send this chronicle to Excalibur support for analysis."
    log_info "The file can be imported into Grafana/Loki with:"
    log_info "  scripts/debug/import-logs.sh ${output_path_final}"
}

main
