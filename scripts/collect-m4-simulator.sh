#!/usr/bin/env bash
# Collect one qualification run from an already-built Release Simulator app.
#
# App-authored artifacts remain byte-for-byte separate from host RSS samples and
# collector metadata. The latter are intentionally labelled supplemental: host
# `ps` sampling is useful context, but it is not an Instruments measurement.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BUNDLE_ID="com.pocketlm.app"
EXPECTED_DEVICE_NAME="iPhone 15 Pro"
EXPECTED_RUNTIME_KEY="com.apple.CoreSimulator.SimRuntime.iOS-17-5"
DEFAULT_TIMEOUT_SECONDS=10800
DEFAULT_POLL_INTERVAL_SECONDS=2
DEFAULT_SAMPLE_INTERVAL_SECONDS=1

SIMULATOR_UDID=""
OUTPUT_DIRECTORY_INPUT=""
APP_PATH_INPUT="${POCKETLM_M4_APP_PATH:-}"
DERIVED_DATA_INPUT="${POCKETLM_M4_DERIVED_DATA:-}"
MODEL_SOURCE=""
SUITE="all"
TIMEOUT_SECONDS="$DEFAULT_TIMEOUT_SECONDS"
POLL_INTERVAL_SECONDS="$DEFAULT_POLL_INTERVAL_SECONDS"
SAMPLE_INTERVAL_SECONDS="$DEFAULT_SAMPLE_INTERVAL_SECONDS"
AUTORUN_DELAY_SECONDS=0

usage() {
    cat <<USAGE
Usage: $0 --udid UDID --output-dir DIRECTORY [options]

Required:
  --udid UDID                    iPhone 15 Pro / iOS 17.5 Simulator UDID
  --output-dir DIRECTORY         Destination for the run and host sidecars

App selection (an already-built Release app is required):
  --app PATH                     Explicit PocketLM.app product
  --derived-data PATH            Locate PocketLM.app in this DerivedData root
                                 (otherwise checks standard Release locations)

Run options:
  --suite all|memory             Qualification suite (default: all)
  --timeout-seconds N            Overall result timeout (default: 10800)
  --poll-interval-seconds N      Artifact poll interval (default: 2)
  --sample-interval-seconds N    External RSS interval (default: 1)
  --autorun-delay-seconds N      Delay after READY/PID and before deep link
                                 (default: 0; useful for attaching xctrace)
  --model-source PATH            Verified source passed to model seeding

The app writes a unique qualification results directory. A collector-generated
nonce binds the deep link, latest pointer, manifest, and terminal sentinel so
another run cannot be mistaken for this request. This collector copies that
directory unchanged to OUTPUT_DIRECTORY/<run-id> and writes two sibling files:
<run-id>.external-rss.jsonl and <run-id>.collector.json. Existing artifacts are
never overwritten; a unique collection suffix is used on collision.
USAGE
}

fail() {
    echo "Qualification collector: $*" >&2
    exit 1
}

is_nonnegative_number() {
    [[ "$1" =~ ^([0-9]+)(\.[0-9]+)?$ ]]
}

is_positive_number() {
    is_nonnegative_number "$1" && ruby -e 'exit(ARGV.fetch(0).to_f > 0 ? 0 : 1)' "$1"
}

is_safe_run_id() {
    [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]]
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --udid)
            [[ $# -ge 2 ]] || { echo "--udid requires a value." >&2; exit 2; }
            SIMULATOR_UDID="$2"
            shift 2
            ;;
        --output-dir)
            [[ $# -ge 2 ]] || { echo "--output-dir requires a path." >&2; exit 2; }
            OUTPUT_DIRECTORY_INPUT="$2"
            shift 2
            ;;
        --app)
            [[ $# -ge 2 ]] || { echo "--app requires a path." >&2; exit 2; }
            APP_PATH_INPUT="$2"
            shift 2
            ;;
        --derived-data)
            [[ $# -ge 2 ]] || { echo "--derived-data requires a path." >&2; exit 2; }
            DERIVED_DATA_INPUT="$2"
            shift 2
            ;;
        --suite)
            [[ $# -ge 2 ]] || { echo "--suite requires all or memory." >&2; exit 2; }
            SUITE="$2"
            shift 2
            ;;
        --timeout-seconds)
            [[ $# -ge 2 ]] || { echo "--timeout-seconds requires a value." >&2; exit 2; }
            TIMEOUT_SECONDS="$2"
            shift 2
            ;;
        --poll-interval-seconds)
            [[ $# -ge 2 ]] || { echo "--poll-interval-seconds requires a value." >&2; exit 2; }
            POLL_INTERVAL_SECONDS="$2"
            shift 2
            ;;
        --sample-interval-seconds)
            [[ $# -ge 2 ]] || { echo "--sample-interval-seconds requires a value." >&2; exit 2; }
            SAMPLE_INTERVAL_SECONDS="$2"
            shift 2
            ;;
        --autorun-delay-seconds)
            [[ $# -ge 2 ]] || { echo "--autorun-delay-seconds requires a value." >&2; exit 2; }
            AUTORUN_DELAY_SECONDS="$2"
            shift 2
            ;;
        --model-source)
            [[ $# -ge 2 ]] || { echo "--model-source requires a path." >&2; exit 2; }
            MODEL_SOURCE="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

[[ -n "$SIMULATOR_UDID" ]] || { usage >&2; exit 2; }
[[ -n "$OUTPUT_DIRECTORY_INPUT" ]] || { usage >&2; exit 2; }
[[ "$SIMULATOR_UDID" =~ ^[A-Za-z0-9-]+$ ]] || fail "UDID contains invalid characters."
case "$SUITE" in
    all|memory) ;;
    *) fail "--suite must be all or memory." ;;
esac
[[ "$TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]] || fail "timeout must be a positive integer."
is_positive_number "$POLL_INTERVAL_SECONDS" || fail "poll interval must be positive."
is_positive_number "$SAMPLE_INTERVAL_SECONDS" || fail "sample interval must be positive."
is_nonnegative_number "$AUTORUN_DELAY_SECONDS" || fail "autorun delay must be nonnegative."
if [[ -n "$MODEL_SOURCE" ]]; then
    [[ -f "$MODEL_SOURCE" && ! -L "$MODEL_SOURCE" ]] || fail "model source is not a regular file."
fi

for command in xcrun ruby plutil shasum ps tr wc cp mv mkdir find grep sleep date \
    basename dirname mktemp kill rmdir rm; do
    command -v "$command" >/dev/null 2>&1 || fail "$command is required."
done

if [[ -n "${POCKETLM_M4_SEED_SCRIPT:-}" && \
      "${POCKETLM_M4_ALLOW_TEST_OVERRIDES:-0}" != "1" ]]; then
    fail "POCKETLM_M4_SEED_SCRIPT is reserved for isolated shell tests."
fi
SEED_SCRIPT="${POCKETLM_M4_SEED_SCRIPT:-${SCRIPT_DIR}/seed-simulator-model.sh}"
[[ -f "$SEED_SCRIPT" && -x "$SEED_SCRIPT" ]] || fail "model seed script is unavailable or not executable."
COLLECTOR_NONCE=$(ruby -rsecurerandom -e 'puts SecureRandom.hex(16)')
[[ "$COLLECTOR_NONCE" =~ ^[0-9a-f]{32}$ ]] || fail "unable to generate the collector correlation nonce."

canonical_directory() {
    (cd "$1" && pwd -P)
}

canonical_file() {
    local parent
    local leaf
    parent=$(canonical_directory "$(dirname "$1")")
    leaf=$(basename "$1")
    printf '%s/%s\n' "$parent" "$leaf"
}

resolve_app_path() {
    local candidate
    local selected
    local -a candidates=()

    if [[ -n "$APP_PATH_INPUT" ]]; then
        [[ -d "$APP_PATH_INPUT" ]] || fail "the supplied app product is not a directory."
        APP_PATH=$(canonical_file "$APP_PATH_INPUT")
        return
    fi

    if [[ -n "$DERIVED_DATA_INPUT" ]]; then
        [[ -d "$DERIVED_DATA_INPUT" ]] || fail "the supplied DerivedData root is not a directory."
        candidate="${DERIVED_DATA_INPUT}/Build/Products/Release-iphonesimulator/PocketLM.app"
        [[ -d "$candidate" ]] || fail "no Release PocketLM.app exists in the supplied DerivedData root."
        APP_PATH=$(canonical_file "$candidate")
        return
    fi

    for candidate in \
        "${REPOSITORY_ROOT}/app/ios/build/Build/Products/Release-iphonesimulator/PocketLM.app" \
        "${REPOSITORY_ROOT}/build/Build/Products/Release-iphonesimulator/PocketLM.app"; do
        [[ -d "$candidate" ]] && candidates+=("$(canonical_file "$candidate")")
    done
    if [[ -n "${HOME:-}" ]]; then
        for candidate in \
            "${HOME}"/Library/Developer/Xcode/DerivedData/*/Build/Products/Release-iphonesimulator/PocketLM.app; do
            [[ -d "$candidate" ]] && candidates+=("$(canonical_file "$candidate")")
        done
    fi

    [[ ${#candidates[@]} -gt 0 ]] || fail "no already-built Release PocketLM.app was found; pass --app."
    selected=$(ruby -e '
      paths = ARGV.select { |path| File.directory?(path) }
      abort "no candidates" if paths.empty?
      puts paths.max_by { |path| File.mtime(path) }
    ' "${candidates[@]}")
    APP_PATH="$selected"
    if [[ ${#candidates[@]} -gt 1 ]]; then
        echo "Qualification collector: located the newest of ${#candidates[@]} Release Simulator app products."
    fi
}

APP_PATH=""
resolve_app_path
[[ "$(basename "$APP_PATH")" == "PocketLM.app" ]] || fail "app product must be named PocketLM.app."
INFO_PLIST="${APP_PATH}/Info.plist"
[[ -f "$INFO_PLIST" && ! -L "$INFO_PLIST" ]] || fail "app Info.plist is unavailable."

APP_BUNDLE_ID=$(plutil -extract CFBundleIdentifier raw -expect string -- "$INFO_PLIST" 2>/dev/null) || \
    fail "app bundle identifier is unreadable."
[[ "$APP_BUNDLE_ID" == "$BUNDLE_ID" ]] || fail "app bundle identifier does not match $BUNDLE_ID."
APP_EXECUTABLE_NAME=$(plutil -extract CFBundleExecutable raw -expect string -- "$INFO_PLIST" 2>/dev/null) || \
    fail "app executable metadata is unreadable."
[[ "$APP_EXECUTABLE_NAME" =~ ^[A-Za-z0-9._-]+$ ]] || fail "app executable name is unsafe."
APP_EXECUTABLE="${APP_PATH}/${APP_EXECUTABLE_NAME}"
MAIN_JS_BUNDLE="${APP_PATH}/main.jsbundle"
[[ -f "$APP_EXECUTABLE" && ! -L "$APP_EXECUTABLE" ]] || fail "app executable is unavailable."
[[ -f "$MAIN_JS_BUNDLE" && ! -L "$MAIN_JS_BUNDLE" ]] || \
    fail "Release app must contain an embedded main.jsbundle."

APP_EXECUTABLE_SHA256=$(shasum -a 256 "$APP_EXECUTABLE" 2>/dev/null | ruby -e 'puts $stdin.read.split.fetch(0)')
MAIN_JS_BUNDLE_SHA256=$(shasum -a 256 "$MAIN_JS_BUNDLE" 2>/dev/null | ruby -e 'puts $stdin.read.split.fetch(0)')
APP_VERSION=$(plutil -extract CFBundleShortVersionString raw -expect string -- "$INFO_PLIST" 2>/dev/null || true)
APP_BUILD=$(plutil -extract CFBundleVersion raw -- "$INFO_PLIST" 2>/dev/null || true)
RELEASE_PRODUCT_PATH_OBSERVED=false
if [[ "$APP_PATH" == *"/Release-iphonesimulator/"* ]]; then
    RELEASE_PRODUCT_PATH_OBSERVED=true
else
    echo "Qualification collector: caller-supplied app has embedded JS; Release product directory was not observable."
fi

mkdir -p -- "$OUTPUT_DIRECTORY_INPUT"
OUTPUT_DIRECTORY=$(canonical_directory "$OUTPUT_DIRECTORY_INPUT")
LOCK_DIRECTORY="${OUTPUT_DIRECTORY}/.pocketlm-m4-collector.lock"
if ! mkdir -- "$LOCK_DIRECTORY" 2>/dev/null; then
    fail "another collector is using the output directory (or a stale collector lock exists)."
fi

TEMP_PARENT=$(canonical_directory "${TMPDIR:-/tmp}")
if ! TEMP_ROOT=$(mktemp -d "${TEMP_PARENT}/pocketlm-m4-collector.XXXXXX"); then
    rmdir -- "$LOCK_DIRECTORY" >/dev/null 2>&1 || true
    fail "unable to create a collector temporary directory."
fi
RSS_TEMP="${TEMP_ROOT}/external-rss.jsonl"
SEED_LOG="${TEMP_ROOT}/seed.log"
BASELINE_RUNS="${TEMP_ROOT}/baseline-runs.txt"
: > "$RSS_TEMP"
: > "$BASELINE_RUNS"

SAMPLE_JOB_PID=""
TARGET_PID=""
DATA_CONTAINER=""
M4_ROOT=""
CURRENT_RUN_ID=""
CURRENT_RUN_PATH=""
PRIOR_LATEST_EXISTS=false
PRIOR_LATEST_SHA256=""
PRIOR_LATEST_RUN_ID=""
LATEST_AFTER_SHA256=""
LATEST_AFTER_RUN_ID=""
RUN_STARTED=0
FINALIZE_ATTEMPTED=0
FINALIZED=0
CAPTURE_KEY=""
COLLECTION_STARTED_AT=$(ruby -rtime -e 'puts Time.now.utc.iso8601(6)')
COLLECTION_FINISHED_AT=""

stop_sampler() {
    if [[ -n "$SAMPLE_JOB_PID" ]]; then
        kill "$SAMPLE_JOB_PID" >/dev/null 2>&1 || true
        wait "$SAMPLE_JOB_PID" >/dev/null 2>&1 || true
        SAMPLE_JOB_PID=""
    fi
}

safe_remove_temp_root() {
    if [[ -n "${TEMP_ROOT:-}" && -d "$TEMP_ROOT" && \
          "$TEMP_ROOT" == "${TEMP_PARENT}"/pocketlm-m4-collector.* ]]; then
        rm -rf -- "$TEMP_ROOT"
    fi
}

release_lock() {
    if [[ -n "${LOCK_DIRECTORY:-}" && -d "$LOCK_DIRECTORY" ]]; then
        rmdir -- "$LOCK_DIRECTORY" >/dev/null 2>&1 || true
    fi
}

parse_run_id_file() {
    local path="$1"
    ruby -rjson -e '
      value = JSON.parse(File.binread(ARGV.fetch(0)))
      run_id = value["runId"]
      abort "missing runId" unless run_id.is_a?(String)
      puts run_id
    ' "$path" 2>/dev/null || true
}

parse_expected_run_id_file() {
    local path="$1"
    ruby -rjson -e '
      value = JSON.parse(File.binread(ARGV.fetch(0)))
      run_id = value["runId"]
      abort "missing runId" unless run_id.is_a?(String)
      abort "wrong suite" unless value["suite"] == ARGV.fetch(1)
      abort "wrong collector nonce" unless value["collectorNonce"] == ARGV.fetch(2)
      puts run_id
    ' "$path" "$SUITE" "$COLLECTOR_NONCE" 2>/dev/null || true
}

latest_fingerprint() {
    local path="$1"
    if [[ -f "$path" && ! -L "$path" ]]; then
        shasum -a 256 "$path" | ruby -e 'puts $stdin.read.split.fetch(0)'
    fi
}

is_baseline_run() {
    grep -F -x -q -- "$1" "$BASELINE_RUNS"
}

run_directory_matches_collector() {
    local path="$1"
    local run_id="$2"
    local filename
    for filename in manifest.json COMPLETE.json FAILED.json; do
        [[ -f "${path}/${filename}" && ! -L "${path}/${filename}" ]] || continue
        if ruby -rjson -e '
          value = JSON.parse(File.binread(ARGV.fetch(0)))
          abort "wrong run" unless value["runId"] == ARGV.fetch(1)
          abort "wrong suite" unless (value["selectedSuite"] || value["suite"]) == ARGV.fetch(2)
          abort "wrong collector nonce" unless value["collectorNonce"] == ARGV.fetch(3)
        ' "${path}/${filename}" "$run_id" "$SUITE" "$COLLECTOR_NONCE" 2>/dev/null; then
            return 0
        fi
    done
    return 1
}

discover_fresh_run() {
    local latest_path="${M4_ROOT}/latest.json"
    local latest_sha=""
    local candidate_id=""
    local entry
    local entry_id
    local -a new_ids=()

    if [[ -f "$latest_path" && ! -L "$latest_path" ]]; then
        latest_sha=$(latest_fingerprint "$latest_path")
        if [[ -n "$latest_sha" && "$latest_sha" != "$PRIOR_LATEST_SHA256" ]]; then
            candidate_id=$(parse_expected_run_id_file "$latest_path")
            if is_safe_run_id "$candidate_id" && ! is_baseline_run "$candidate_id" && \
               [[ -d "${M4_ROOT}/${candidate_id}" && ! -L "${M4_ROOT}/${candidate_id}" ]]; then
                CURRENT_RUN_ID="$candidate_id"
                CURRENT_RUN_PATH="${M4_ROOT}/${candidate_id}"
                return 0
            fi
        fi
    fi

    if [[ -d "$M4_ROOT" ]]; then
        for entry in "${M4_ROOT}"/*; do
            [[ -d "$entry" && ! -L "$entry" ]] || continue
            entry_id=$(basename "$entry")
            is_safe_run_id "$entry_id" || continue
            if ! is_baseline_run "$entry_id" && \
               run_directory_matches_collector "$entry" "$entry_id"; then
                new_ids+=("$entry_id")
            fi
        done
    fi
    if [[ ${#new_ids[@]} -eq 1 ]]; then
        CURRENT_RUN_ID="${new_ids[0]}"
        CURRENT_RUN_PATH="${M4_ROOT}/${CURRENT_RUN_ID}"
        return 0
    fi
    return 1
}

sentinel_is_valid() {
    local path="$1"
    ruby -rjson -e '
      value = JSON.parse(File.binread(ARGV.fetch(0)))
      abort "wrong run" unless value["runId"] == ARGV.fetch(1)
      abort "wrong suite" unless value["suite"] == ARGV.fetch(2)
      abort "wrong collector nonce" unless value["collectorNonce"] == ARGV.fetch(3)
    ' "$path" "$CURRENT_RUN_ID" "$SUITE" "$COLLECTOR_NONCE" 2>/dev/null
}

append_rss_sample() {
    local rss_kib
    local rss_bytes
    rss_kib=$(ps -o rss= -p "$TARGET_PID" 2>/dev/null | tr -d '[:space:]')
    [[ "$rss_kib" =~ ^[0-9]+$ ]] || return 1
    rss_bytes=$((rss_kib * 1024))
    ruby -rjson -rtime -e '
      record = {
        "schemaVersion" => 1,
        "classification" => "external-host-rss-supplemental",
        "scope" => "iOS Simulator target process",
        "timestampUtc" => Time.now.utc.iso8601(6),
        "hostMonotonicMs" => Process.clock_gettime(Process::CLOCK_MONOTONIC, :float_millisecond),
        "pid" => Integer(ARGV.fetch(0), 10),
        "rssBytes" => Integer(ARGV.fetch(1), 10)
      }
      puts JSON.generate(record)
    ' "$TARGET_PID" "$rss_bytes" >> "$RSS_TEMP"
}

start_sampler() {
    append_rss_sample || fail "cold-launched app process is not sampleable."
    (
        while sleep "$SAMPLE_INTERVAL_SECONDS"; do
            append_rss_sample || break
        done
    ) &
    SAMPLE_JOB_PID=$!
}

choose_capture_key() {
    local base="$1"
    local candidate="$base"
    local suffix
    local counter=0

    while [[ -e "${OUTPUT_DIRECTORY}/${candidate}" || \
             -e "${OUTPUT_DIRECTORY}/${candidate}.external-rss.jsonl" || \
             -e "${OUTPUT_DIRECTORY}/${candidate}.collector.json" ]]; do
        counter=$((counter + 1))
        suffix="$(date -u +%Y%m%dT%H%M%SZ)-$$-${counter}"
        candidate="${base}-collection-${suffix}"
    done
    CAPTURE_KEY="$candidate"
}

write_collector_metadata() {
    local state="$1"
    local sentinel="$2"
    local copy_complete="$3"
    local sample_count="$4"
    local run_id_or_empty="$CURRENT_RUN_ID"
    local run_directory_or_empty=""
    local metadata_temp="${TEMP_ROOT}/collector.json"

    if [[ -n "$CURRENT_RUN_ID" ]]; then
        run_directory_or_empty="$CAPTURE_KEY"
    fi
    ruby -rjson -e '
      nullable = ->(value) { value.empty? ? nil : value }
      boolean = ->(value) { value == "true" }
      document = {
        "schemaVersion" => 1,
        "artifactClass" => "external Simulator host collector metadata",
        "classification" => "supplemental",
        "status" => ARGV.fetch(0),
        "runId" => nullable.call(ARGV.fetch(1)),
        "selectedSuite" => ARGV.fetch(2),
        "collectorNonce" => ARGV.fetch(3),
        "terminalSentinel" => nullable.call(ARGV.fetch(4)),
        "collectionStartedAt" => ARGV.fetch(5),
        "collectionFinishedAt" => ARGV.fetch(6),
        "target" => {
          "platform" => "iOS Simulator",
          "deviceName" => ARGV.fetch(7),
          "runtime" => "iOS 17.5",
          "udid" => ARGV.fetch(8),
          "bundleId" => ARGV.fetch(9)
        },
        "app" => {
          "buildModeClaim" => "Release (caller supplied; embedded JavaScript verified)",
          "releaseProductDirectoryObserved" => boolean.call(ARGV.fetch(10)),
          "version" => nullable.call(ARGV.fetch(11)),
          "build" => nullable.call(ARGV.fetch(12)),
          "executableSha256" => ARGV.fetch(13),
          "mainJsBundleSha256" => ARGV.fetch(14)
        },
        "launch" => {
          "coldLaunch" => true,
          "pid" => Integer(ARGV.fetch(15), 10),
          "deepLink" => "pocketlm://bench?autorun=1&collectorNonce=#{ARGV.fetch(3)}&suite=#{ARGV.fetch(2)}",
          "autorunDelaySeconds" => ARGV.fetch(16).to_f
        },
        "freshness" => {
          "priorLatest" => {
            "exists" => boolean.call(ARGV.fetch(17)),
            "sha256" => nullable.call(ARGV.fetch(18)),
            "runId" => nullable.call(ARGV.fetch(19))
          },
          "latestAfter" => {
            "sha256" => nullable.call(ARGV.fetch(20)),
            "runId" => nullable.call(ARGV.fetch(21))
          },
          "runDirectoryWasNew" => !ARGV.fetch(1).empty?
        },
        "copiedRunDirectory" => nullable.call(ARGV.fetch(22)),
        "runCopyComplete" => boolean.call(ARGV.fetch(23)),
        "externalRss" => {
          "classification" => "external-host-rss-supplemental",
          "method" => "host ps RSS sampling of the cold-launched Simulator process",
          "units" => "bytes",
          "sampleIntervalSeconds" => ARGV.fetch(24).to_f,
          "sampleCount" => Integer(ARGV.fetch(25), 10),
          "filename" => "#{ARGV.fetch(26)}.external-rss.jsonl",
          "isInstrumentsEvidence" => false
        },
        "timeoutSeconds" => Integer(ARGV.fetch(27), 10),
        "limitations" => [
          "Host ps RSS is supplemental and does not replace an Instruments trace.",
          "Simulator measurements are not physical-device or thermal evidence.",
          "No absolute app, host, or Simulator container paths are persisted here."
        ]
      }
      File.binwrite(ARGV.fetch(28), JSON.pretty_generate(document) + "\n")
    ' \
        "$state" "$run_id_or_empty" "$SUITE" "$COLLECTOR_NONCE" "$sentinel" \
        "$COLLECTION_STARTED_AT" "$COLLECTION_FINISHED_AT" \
        "$EXPECTED_DEVICE_NAME" "$SIMULATOR_UDID" "$BUNDLE_ID" \
        "$RELEASE_PRODUCT_PATH_OBSERVED" "$APP_VERSION" "$APP_BUILD" \
        "$APP_EXECUTABLE_SHA256" "$MAIN_JS_BUNDLE_SHA256" "$TARGET_PID" \
        "$AUTORUN_DELAY_SECONDS" "$PRIOR_LATEST_EXISTS" "$PRIOR_LATEST_SHA256" \
        "$PRIOR_LATEST_RUN_ID" "$LATEST_AFTER_SHA256" "$LATEST_AFTER_RUN_ID" \
        "$run_directory_or_empty" "$copy_complete" "$SAMPLE_INTERVAL_SECONDS" \
        "$sample_count" "$CAPTURE_KEY" "$TIMEOUT_SECONDS" "$metadata_temp" 2>/dev/null
    mv -- "$metadata_temp" "${OUTPUT_DIRECTORY}/${CAPTURE_KEY}.collector.json" 2>/dev/null
}

finalize_artifacts() {
    local state="$1"
    local sentinel="$2"
    local copy_complete=true
    local latest_path="${M4_ROOT}/latest.json"
    local sample_count
    local base_key
    local destination

    [[ "$FINALIZE_ATTEMPTED" -eq 0 ]] || return 0
    FINALIZE_ATTEMPTED=1
    stop_sampler
    COLLECTION_FINISHED_AT=$(ruby -rtime -e 'puts Time.now.utc.iso8601(6)')

    if [[ -f "$latest_path" && ! -L "$latest_path" ]]; then
        LATEST_AFTER_SHA256=$(latest_fingerprint "$latest_path")
        LATEST_AFTER_RUN_ID=$(parse_run_id_file "$latest_path")
        is_safe_run_id "$LATEST_AFTER_RUN_ID" || LATEST_AFTER_RUN_ID=""
    fi

    if [[ -n "$CURRENT_RUN_ID" ]]; then
        base_key="$CURRENT_RUN_ID"
    else
        base_key="collector-$(date -u +%Y%m%dT%H%M%SZ)-$$"
    fi
    choose_capture_key "$base_key"

    if [[ -n "$CURRENT_RUN_PATH" && -d "$CURRENT_RUN_PATH" && ! -L "$CURRENT_RUN_PATH" ]]; then
        destination="${OUTPUT_DIRECTORY}/${CAPTURE_KEY}"
        if [[ -n "$(find "$CURRENT_RUN_PATH" -type l -print -quit 2>/dev/null)" ]]; then
            copy_complete=false
        elif ! mkdir -- "$destination" 2>/dev/null; then
            copy_complete=false
        elif ! cp -pR "$CURRENT_RUN_PATH"/. "$destination"/ 2>/dev/null; then
            copy_complete=false
        fi
    elif [[ -n "$CURRENT_RUN_ID" ]]; then
        copy_complete=false
    fi

    sample_count=$(wc -l < "$RSS_TEMP" | tr -d '[:space:]')
    [[ "$sample_count" =~ ^[0-9]+$ ]] || sample_count=0
    if ! mv -- "$RSS_TEMP" "${OUTPUT_DIRECTORY}/${CAPTURE_KEY}.external-rss.jsonl" 2>/dev/null; then
        echo "Qualification collector: unable to preserve external RSS samples." >&2
        return 1
    fi
    if [[ "$copy_complete" != true ]]; then
        state="collector-error"
    fi
    if ! write_collector_metadata "$state" "$sentinel" "$copy_complete" "$sample_count"; then
        echo "Qualification collector: unable to preserve collector metadata." >&2
        return 1
    fi
    FINALIZED=1

    echo "Qualification collector: preserved collection ${CAPTURE_KEY} (${state}); RSS is an external supplemental metric."
    [[ "$copy_complete" == true ]]
}

on_exit() {
    local status=$?
    trap - EXIT
    set +e
    stop_sampler
    if [[ "$RUN_STARTED" -eq 1 && "$FINALIZED" -eq 0 && "$FINALIZE_ATTEMPTED" -eq 0 ]]; then
        finalize_artifacts "collector-error" ""
    fi
    safe_remove_temp_root
    release_lock
    exit "$status"
}
trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

DEVICE_RECORD=$(xcrun simctl list devices --json | ruby -rjson -e '
  wanted = ARGV.fetch(0)
  document = JSON.parse($stdin.read)
  matches = []
  document.fetch("devices").each do |runtime, devices|
    devices.each do |device|
      next unless device["udid"] == wanted
      matches << [device["name"], device["state"], runtime,
                  device.fetch("isAvailable", true)]
    end
  end
  abort "Simulator UDID was not found" unless matches.length == 1
  puts matches.fetch(0).join("\t")
' "$SIMULATOR_UDID")
IFS=$'\t' read -r DEVICE_NAME DEVICE_STATE DEVICE_RUNTIME DEVICE_AVAILABLE <<< "$DEVICE_RECORD"
[[ "$DEVICE_NAME" == "$EXPECTED_DEVICE_NAME" ]] || fail "UDID is not an $EXPECTED_DEVICE_NAME Simulator."
[[ "$DEVICE_RUNTIME" == "$EXPECTED_RUNTIME_KEY" ]] || fail "UDID is not on the iOS 17.5 runtime."
[[ "$DEVICE_AVAILABLE" == "true" ]] || fail "Simulator is unavailable."
case "$DEVICE_STATE" in
    Booted)
        ;;
    Shutdown)
        xcrun simctl boot "$SIMULATOR_UDID" >/dev/null
        ;;
    *)
        fail "Simulator must be Booted or Shutdown, not $DEVICE_STATE."
        ;;
esac
xcrun simctl bootstatus "$SIMULATOR_UDID" -b >/dev/null

echo "Qualification collector: installing validated Release Simulator app."
if ! xcrun simctl install "$SIMULATOR_UDID" "$APP_PATH" >/dev/null 2>&1; then
    fail "Simulator app installation failed."
fi

SEED_ARGUMENTS=(--udid "$SIMULATOR_UDID")
if [[ -n "$MODEL_SOURCE" ]]; then
    SEED_ARGUMENTS+=(--source "$MODEL_SOURCE")
fi
if ! "$SEED_SCRIPT" "${SEED_ARGUMENTS[@]}" >"$SEED_LOG" 2>&1; then
    fail "verified Simulator model seeding failed; rerun the seed script directly for diagnostics."
fi
echo "Qualification collector: verified Simulator model seed completed."

DATA_CONTAINER=$(xcrun simctl get_app_container "$SIMULATOR_UDID" "$BUNDLE_ID" data 2>/dev/null)
[[ "$DATA_CONTAINER" == /* && -d "$DATA_CONTAINER" ]] || fail "simctl returned an invalid app data container."
M4_ROOT="${DATA_CONTAINER}/Documents/PocketLM/M4"
mkdir -p -- "$M4_ROOT" 2>/dev/null || fail "unable to prepare the app-authored qualification artifact root."
case "${OUTPUT_DIRECTORY}/" in
    "${M4_ROOT}/"*) fail "output directory must be outside the app-authored qualification artifact root." ;;
esac

TERMINATE_OUTPUT=""
if ! TERMINATE_OUTPUT=$(xcrun simctl terminate "$SIMULATOR_UDID" "$BUNDLE_ID" 2>&1); then
    case "$TERMINATE_OUTPUT" in
        *"found nothing to terminate"*|*"not running"*) ;;
        *) fail "unable to terminate the app before the cold launch." ;;
    esac
fi

# Snapshot only after the old process is fenced. This is defense in depth; the
# collector nonce remains the authoritative correlation for the requested run.
for entry in "${M4_ROOT}"/*; do
    [[ -d "$entry" && ! -L "$entry" ]] || continue
    entry_id=$(basename "$entry")
    is_safe_run_id "$entry_id" && printf '%s\n' "$entry_id" >> "$BASELINE_RUNS"
done
PRIOR_LATEST_PATH="${M4_ROOT}/latest.json"
if [[ -f "$PRIOR_LATEST_PATH" && ! -L "$PRIOR_LATEST_PATH" ]]; then
    PRIOR_LATEST_EXISTS=true
    PRIOR_LATEST_SHA256=$(latest_fingerprint "$PRIOR_LATEST_PATH")
    PRIOR_LATEST_RUN_ID=$(parse_run_id_file "$PRIOR_LATEST_PATH")
    is_safe_run_id "$PRIOR_LATEST_RUN_ID" || PRIOR_LATEST_RUN_ID=""
fi

LAUNCH_OUTPUT=$(xcrun simctl launch --terminate-running-process "$SIMULATOR_UDID" "$BUNDLE_ID")
if [[ "$LAUNCH_OUTPUT" =~ :[[:space:]]*([0-9]+) ]]; then
    TARGET_PID="${BASH_REMATCH[1]}"
else
    fail "simctl launch did not report a target PID."
fi
[[ "$TARGET_PID" =~ ^[1-9][0-9]*$ ]] || fail "simctl launch returned an invalid PID."
start_sampler

echo "POCKETLM_M4_READY pid=${TARGET_PID} suite=${SUITE} collector_nonce=${COLLECTOR_NONCE} autorun_delay_seconds=${AUTORUN_DELAY_SECONDS}"
if [[ "$AUTORUN_DELAY_SECONDS" != "0" && "$AUTORUN_DELAY_SECONDS" != "0.0" ]]; then
    sleep "$AUTORUN_DELAY_SECONDS"
fi

RUN_STARTED=1
xcrun simctl openurl "$SIMULATOR_UDID" \
    "pocketlm://bench?autorun=1&collectorNonce=${COLLECTOR_NONCE}&suite=${SUITE}" >/dev/null
echo "Qualification collector: autorun requested; waiting for a fresh terminal artifact."

DEADLINE=$((SECONDS + TIMEOUT_SECONDS))
TERMINAL_STATE=""
TERMINAL_SENTINEL=""
TERMINAL_EXIT_CODE=1
while (( SECONDS < DEADLINE )); do
    if [[ -z "$CURRENT_RUN_ID" ]]; then
        discover_fresh_run || true
        if [[ -n "$CURRENT_RUN_ID" ]]; then
            echo "Qualification collector: observed fresh run ${CURRENT_RUN_ID}."
        fi
    fi

    if [[ -n "$CURRENT_RUN_PATH" ]]; then
        COMPLETE_PATH="${CURRENT_RUN_PATH}/COMPLETE.json"
        FAILED_PATH="${CURRENT_RUN_PATH}/FAILED.json"
        if [[ -e "$COMPLETE_PATH" && -e "$FAILED_PATH" ]]; then
            TERMINAL_STATE="protocol-error"
            TERMINAL_EXIT_CODE=5
            break
        elif [[ -f "$COMPLETE_PATH" && ! -L "$COMPLETE_PATH" ]]; then
            if sentinel_is_valid "$COMPLETE_PATH"; then
                TERMINAL_STATE="complete"
                TERMINAL_SENTINEL="COMPLETE.json"
                TERMINAL_EXIT_CODE=0
            else
                TERMINAL_STATE="protocol-error"
                TERMINAL_EXIT_CODE=5
            fi
            break
        elif [[ -f "$FAILED_PATH" && ! -L "$FAILED_PATH" ]]; then
            if sentinel_is_valid "$FAILED_PATH"; then
                TERMINAL_STATE="failed"
                TERMINAL_SENTINEL="FAILED.json"
                TERMINAL_EXIT_CODE=4
            else
                TERMINAL_STATE="protocol-error"
                TERMINAL_EXIT_CODE=5
            fi
            break
        fi
    fi

    if ! ps -p "$TARGET_PID" >/dev/null 2>&1; then
        TERMINAL_STATE="process-exited"
        TERMINAL_EXIT_CODE=6
        break
    fi
    sleep "$POLL_INTERVAL_SECONDS"
done

if [[ -z "$TERMINAL_STATE" ]]; then
    discover_fresh_run || true
    TERMINAL_STATE="timeout"
    TERMINAL_EXIT_CODE=124
fi

if ! finalize_artifacts "$TERMINAL_STATE" "$TERMINAL_SENTINEL"; then
    TERMINAL_EXIT_CODE=1
fi
exit "$TERMINAL_EXIT_CODE"
