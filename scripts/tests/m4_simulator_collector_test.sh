#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
TEST_ROOT=$(mktemp -d "/tmp/pocketlm-m4-collector-test.XXXXXX")
trap 'rm -rf -- "$TEST_ROOT"' EXIT

FAKE_BIN="${TEST_ROOT}/bin"
APP_PATH="${TEST_ROOT}/DerivedData/Build/Products/Release-iphonesimulator/PocketLM.app"
SIMULATOR_CONTAINER="${TEST_ROOT}/simulator-data"
M4_ROOT="${SIMULATOR_CONTAINER}/Documents/PocketLM/M4"
OUTPUT_ROOT="${TEST_ROOT}/output"
XCRUN_LOG="${TEST_ROOT}/xcrun.log"
SEED_LOG="${TEST_ROOT}/seed.log"
COLLECTOR_LOG="${TEST_ROOT}/collector.log"
FAKE_UDID="11111111-2222-3333-4444-555555555555"

mkdir -p "$FAKE_BIN" "$APP_PATH" "$M4_ROOT" "$OUTPUT_ROOT"
plutil -create xml1 "${APP_PATH}/Info.plist"
plutil -insert CFBundleIdentifier -string com.pocketlm.app "${APP_PATH}/Info.plist"
plutil -insert CFBundleExecutable -string PocketLM "${APP_PATH}/Info.plist"
plutil -insert CFBundleShortVersionString -string 0.1.0 "${APP_PATH}/Info.plist"
plutil -insert CFBundleVersion -string 7 "${APP_PATH}/Info.plist"
printf 'fixture executable\n' > "${APP_PATH}/PocketLM"
printf 'fixture embedded JavaScript\n' > "${APP_PATH}/main.jsbundle"

mkdir -p "${M4_ROOT}/old-run"
cat > "${M4_ROOT}/old-run/COMPLETE.json" <<'JSON'
{"schemaVersion":1,"runId":"old-run","suite":"all"}
JSON
cat > "${M4_ROOT}/latest.json" <<'JSON'
{"runId":"old-run","suite":"all","createdAt":"2026-01-01T00:00:00Z"}
JSON

cat > "${FAKE_BIN}/xcrun" <<'FAKE_XCRUN'
#!/usr/bin/env bash
set -euo pipefail

[[ "$1" == "simctl" ]]
command_name="$2"
shift 2
case "$command_name" in
    list)
        cat <<JSON
{"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-17-5":[{"state":"Booted","isAvailable":true,"name":"iPhone 15 Pro","udid":"${POCKETLM_FAKE_UDID}"}]}}
JSON
        ;;
    bootstatus)
        printf 'bootstatus %s\n' "$*" >> "${POCKETLM_FAKE_XCRUN_LOG}"
        ;;
    boot)
        printf 'boot %s\n' "$*" >> "${POCKETLM_FAKE_XCRUN_LOG}"
        ;;
    install)
        printf 'install %s\n' "$*" >> "${POCKETLM_FAKE_XCRUN_LOG}"
        ;;
    get_app_container)
        [[ "$1" == "${POCKETLM_FAKE_UDID}" ]]
        [[ "$2" == "com.pocketlm.app" ]]
        [[ "$3" == "data" ]]
        printf '%s\n' "${POCKETLM_FAKE_SIMULATOR_CONTAINER}"
        ;;
    terminate)
        printf 'terminate %s\n' "$*" >> "${POCKETLM_FAKE_XCRUN_LOG}"
        ;;
    launch)
        printf 'launch %s\n' "$*" >> "${POCKETLM_FAKE_XCRUN_LOG}"
        printf 'com.pocketlm.app: %s\n' "${POCKETLM_FAKE_APP_PID}"
        ;;
    openurl)
        printf 'openurl %s\n' "$*" >> "${POCKETLM_FAKE_XCRUN_LOG}"
        url="$2"
        suite="${url##*suite=}"
        nonce_tail="${url#*collectorNonce=}"
        collector_nonce="${nonce_tail%%&*}"
        [[ "$collector_nonce" =~ ^[0-9a-f]{32}$ ]]
        run_id="${POCKETLM_FAKE_RUN_ID}"
        artifact_nonce="$collector_nonce"
        if [[ "${POCKETLM_FAKE_RUN_MODE}" == "hostile" ]]; then
            artifact_nonce="00000000000000000000000000000000"
            [[ "$artifact_nonce" != "$collector_nonce" ]]
        fi
        run_directory="${POCKETLM_FAKE_SIMULATOR_CONTAINER}/Documents/PocketLM/M4/${run_id}"
        mkdir -p "$run_directory"
        printf '{"schemaVersion":1,"runId":"%s","collectorNonce":"%s","selectedSuite":"%s","status":"running"}\n' \
            "$run_id" "$artifact_nonce" "$suite" > "${run_directory}/manifest.json"
        printf '{"runId":"%s","suite":"%s","collectorNonce":"%s","createdAt":"%s"}\n' \
            "$run_id" "$suite" "$artifact_nonce" "${POCKETLM_FAKE_RUN_ID}" > \
            "${POCKETLM_FAKE_SIMULATOR_CONTAINER}/Documents/PocketLM/M4/latest.json"
        case "${POCKETLM_FAKE_RUN_MODE}" in
            complete)
                printf '{"schemaVersion":1,"runId":"%s","suite":"%s","collectorNonce":"%s"}\n' \
                    "$run_id" "$suite" "$artifact_nonce" > "${run_directory}/COMPLETE.json"
                ;;
            failed)
                printf '{"schemaVersion":1,"runId":"%s","suite":"%s","collectorNonce":"%s","error":{"message":"fixture"}}\n' \
                    "$run_id" "$suite" "$artifact_nonce" > "${run_directory}/FAILED.json"
                ;;
            partial)
                ;;
            hostile)
                printf '{"schemaVersion":1,"runId":"%s","suite":"%s","collectorNonce":"%s"}\n' \
                    "$run_id" "$suite" "$artifact_nonce" > "${run_directory}/COMPLETE.json"
                ;;
            *)
                echo "unsupported fake run mode" >&2
                exit 2
                ;;
        esac
        ;;
    *)
        echo "unsupported fake simctl invocation: $command_name $*" >&2
        exit 2
        ;;
esac
FAKE_XCRUN
chmod +x "${FAKE_BIN}/xcrun"

cat > "${FAKE_BIN}/fake-seed" <<'FAKE_SEED'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${POCKETLM_FAKE_SEED_LOG}"
FAKE_SEED
chmod +x "${FAKE_BIN}/fake-seed"

cat > "${FAKE_BIN}/ps" <<'FAKE_PS'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == "-o" && "$2" == "rss=" && "$3" == "-p" ]]; then
    echo 12345
elif [[ "$1" == "-p" ]]; then
    printf '  PID TTY           TIME CMD\n%s ??         0:00.01 PocketLM\n' "$2"
else
    echo "unsupported fake ps invocation: $*" >&2
    exit 2
fi
FAKE_PS
chmod +x "${FAKE_BIN}/ps"

export PATH="${FAKE_BIN}:${PATH}"
export POCKETLM_M4_SEED_SCRIPT="${FAKE_BIN}/fake-seed"
export POCKETLM_M4_ALLOW_TEST_OVERRIDES=1
export POCKETLM_FAKE_UDID="$FAKE_UDID"
export POCKETLM_FAKE_SIMULATOR_CONTAINER="$SIMULATOR_CONTAINER"
export POCKETLM_FAKE_XCRUN_LOG="$XCRUN_LOG"
export POCKETLM_FAKE_SEED_LOG="$SEED_LOG"
export POCKETLM_FAKE_APP_PID="$$"

run_collector() {
    local timeout_seconds="${2:-3}"
    "${REPOSITORY_ROOT}/scripts/collect-m4-simulator.sh" \
        --udid "$FAKE_UDID" \
        --output-dir "$OUTPUT_ROOT" \
        --app "$APP_PATH" \
        --suite "$1" \
        --timeout-seconds "$timeout_seconds" \
        --poll-interval-seconds 0.05 \
        --sample-interval-seconds 0.05 \
        --autorun-delay-seconds 0.01
}

export POCKETLM_FAKE_RUN_ID="run-complete"
export POCKETLM_FAKE_RUN_MODE="complete"
run_collector all > "$COLLECTOR_LOG"
[[ -f "${OUTPUT_ROOT}/run-complete/COMPLETE.json" ]]
[[ -s "${OUTPUT_ROOT}/run-complete.external-rss.jsonl" ]]
[[ -f "${OUTPUT_ROOT}/run-complete.collector.json" ]]
diff -r "${M4_ROOT}/run-complete" "${OUTPUT_ROOT}/run-complete"
grep -q '^POCKETLM_M4_READY pid=' "$COLLECTOR_LOG"
grep -Eq 'openurl .*pocketlm://bench\?autorun=1&collectorNonce=[0-9a-f]{32}&suite=all' "$XCRUN_LOG"
grep -q -- '--udid 11111111-2222-3333-4444-555555555555' "$SEED_LOG"
if grep -F -q "$SIMULATOR_CONTAINER" "${OUTPUT_ROOT}/run-complete.collector.json"; then
    echo "collector metadata leaked the private Simulator container path" >&2
    exit 1
fi
ruby -rjson -e '
  metadata = JSON.parse(File.binread(ARGV.fetch(0)))
  abort unless metadata["status"] == "complete"
  abort unless metadata["runId"] == "run-complete"
  nonce = metadata.fetch("collectorNonce")
  abort unless nonce.match?(/\A[0-9a-f]{32}\z/)
  abort unless metadata.dig("launch", "deepLink").include?("collectorNonce=#{nonce}")
  abort unless metadata.dig("freshness", "priorLatest", "runId") == "old-run"
  abort unless metadata.dig("externalRss", "isInstrumentsEvidence") == false
  abort unless metadata.dig("externalRss", "sampleCount") >= 1
' "${OUTPUT_ROOT}/run-complete.collector.json"
ruby -rjson -e '
  File.foreach(ARGV.fetch(0)) do |line|
    sample = JSON.parse(line)
    abort unless sample["classification"] == "external-host-rss-supplemental"
    abort unless sample["rssBytes"].is_a?(Integer) && sample["rssBytes"] > 0
  end
' "${OUTPUT_ROOT}/run-complete.external-rss.jsonl"

# A native/app failure still preserves the exact failed run and host sidecars.
export POCKETLM_FAKE_RUN_ID="run-failed"
export POCKETLM_FAKE_RUN_MODE="failed"
if run_collector memory >> "$COLLECTOR_LOG" 2>&1; then
    echo "collector unexpectedly returned success for FAILED.json" >&2
    exit 1
else
    status=$?
    [[ "$status" -eq 4 ]]
fi
[[ -f "${OUTPUT_ROOT}/run-failed/FAILED.json" ]]
[[ -s "${OUTPUT_ROOT}/run-failed.external-rss.jsonl" ]]
ruby -rjson -e '
  metadata = JSON.parse(File.binread(ARGV.fetch(0)))
  abort unless metadata["status"] == "failed"
  abort unless metadata["selectedSuite"] == "memory"
' "${OUTPUT_ROOT}/run-failed.collector.json"

# An output-name collision never overwrites earlier evidence.
mkdir "${OUTPUT_ROOT}/run-collision"
printf 'preserve me\n' > "${OUTPUT_ROOT}/run-collision/original.txt"
export POCKETLM_FAKE_RUN_ID="run-collision"
export POCKETLM_FAKE_RUN_MODE="complete"
run_collector all >> "$COLLECTOR_LOG" 2>&1
[[ "$(cat "${OUTPUT_ROOT}/run-collision/original.txt")" == "preserve me" ]]
collision_directories=("${OUTPUT_ROOT}"/run-collision-collection-*)
[[ ${#collision_directories[@]} -eq 1 ]]
[[ -f "${collision_directories[0]}/COMPLETE.json" ]]
collision_key=$(basename "${collision_directories[0]}")
[[ -f "${OUTPUT_ROOT}/${collision_key}.collector.json" ]]
[[ -s "${OUTPUT_ROOT}/${collision_key}.external-rss.jsonl" ]]

# A timeout preserves the fresh run directory even without a terminal sentinel.
export POCKETLM_FAKE_RUN_ID="run-partial"
export POCKETLM_FAKE_RUN_MODE="partial"
if run_collector all 1 >> "$COLLECTOR_LOG" 2>&1; then
    echo "collector unexpectedly returned success for a timed-out partial run" >&2
    exit 1
else
    status=$?
    [[ "$status" -eq 124 ]]
fi
[[ -f "${OUTPUT_ROOT}/run-partial/manifest.json" ]]
[[ ! -e "${OUTPUT_ROOT}/run-partial/COMPLETE.json" ]]
[[ -s "${OUTPUT_ROOT}/run-partial.external-rss.jsonl" ]]
ruby -rjson -e '
  metadata = JSON.parse(File.binread(ARGV.fetch(0)))
  abort unless metadata["status"] == "timeout"
  abort unless metadata["runCopyComplete"] == true
' "${OUTPUT_ROOT}/run-partial.collector.json"

# A fresh same-suite run with another nonce must never be attributed to this
# collector request, even though it is the only post-baseline directory and has
# a valid COMPLETE sentinel.
export POCKETLM_FAKE_RUN_ID="run-hostile"
export POCKETLM_FAKE_RUN_MODE="hostile"
if run_collector all 1 >> "$COLLECTOR_LOG" 2>&1; then
    echo "collector misattributed a hostile concurrent run" >&2
    exit 1
else
    status=$?
    [[ "$status" -eq 124 ]]
fi
[[ -f "${M4_ROOT}/run-hostile/COMPLETE.json" ]]
[[ ! -e "${OUTPUT_ROOT}/run-hostile" ]]
hostile_timeout_metadata=("${OUTPUT_ROOT}"/collector-*.collector.json)
[[ ${#hostile_timeout_metadata[@]} -eq 1 ]]
ruby -rjson -e '
  metadata = JSON.parse(File.binread(ARGV.fetch(0)))
  abort unless metadata["status"] == "timeout"
  abort unless metadata["runId"].nil?
  abort unless metadata.fetch("collectorNonce").match?(/\A[0-9a-f]{32}\z/)
' "${hostile_timeout_metadata[0]}"

if grep -F -q "$TEST_ROOT" "$COLLECTOR_LOG"; then
    echo "collector log leaked a private absolute fixture path" >&2
    exit 1
fi

echo "Simulator qualification collector shell tests passed."
