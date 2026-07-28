#!/usr/bin/env bash
# Install the catalog-pinned model into an installed PocketLM Simulator app.
# The app is terminated before a model is installed or replaced, so no native
# session can retain a reference to the destination file during atomic rename.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CATALOG_PATH="${POCKETLM_CATALOG_PATH:-${SCRIPT_DIR}/../models/catalog.json}"
VERIFIER_PATH="${SCRIPT_DIR}/verify-model.rb"
BACKUP_HELPER_PATH="${SCRIPT_DIR}/set-backup-exclusion.swift"
SWIFT_CACHE_PATH="${TMPDIR:-/tmp}/PocketLMSwiftModuleCache"
# shellcheck source=lib/provisioning.sh
source "${SCRIPT_DIR}/lib/provisioning.sh"

BUNDLE_ID="com.pocketlm.app"
MODEL_CACHE_DIR="${POCKETLM_MODEL_CACHE_DIR:-${HOME:?HOME is required}/.pocketlm/models}"
SOURCE_OVERRIDE=""
SIMULATOR_UDID=""
FORCE=0

usage() {
    cat <<USAGE
Usage: $0 [--force] [--source PATH] [--udid SIMULATOR_UDID]

Seeds the exact catalog model into the installed $BUNDLE_ID app sandbox.
The default source is the verified host cache under POCKETLM_MODEL_CACHE_DIR.
--source provides an import path, which must pass the same complete verification.
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --force)
            FORCE=1
            shift
            ;;
        --source)
            [[ $# -ge 2 ]] || { echo "--source requires a path." >&2; exit 2; }
            SOURCE_OVERRIDE="$2"
            shift 2
            ;;
        --udid)
            [[ $# -ge 2 ]] || { echo "--udid requires a Simulator UDID." >&2; exit 2; }
            SIMULATOR_UDID="$2"
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

for command in ruby xcrun df cp mv rm mkdir date; do
    if ! command -v "$command" >/dev/null 2>&1; then
        echo "$command is required for Simulator model seeding." >&2
        exit 1
    fi
done

IFS=$'\t' read -r MODEL_ID MODEL_FILENAME MODEL_URL MODEL_BYTES MODEL_SHA256 \
    MODEL_MAGIC MODEL_GGUF_VERSION MODEL_DIRECTORY_NAME MODEL_INSTALLED_FILENAME \
    CATALOG_SCHEMA_VERSION < <(
        ruby "$VERIFIER_PATH" catalog --catalog "$CATALOG_PATH" --format tsv
    )

if [[ -n "$SOURCE_OVERRIDE" ]]; then
    SOURCE_PATH="$SOURCE_OVERRIDE"
else
    SOURCE_PATH="${MODEL_CACHE_DIR}/${MODEL_FILENAME}"
fi

echo "Verifying host source before touching a Simulator sandbox..."
ruby "$VERIFIER_PATH" verify --catalog "$CATALOG_PATH" "$SOURCE_PATH"

booted_udids() {
    xcrun simctl list devices booted --json | ruby -rjson -e '
      document = JSON.parse($stdin.read)
      document.fetch("devices").each_value do |devices|
        devices.each do |device|
          puts device.fetch("udid") if device["state"] == "Booted" && device.fetch("isAvailable", true)
        end
      end
    '
}

resolve_container() {
    local candidate_udid
    local candidate_container
    local -a installed_udids=()
    local -a installed_containers=()

    if [[ -n "$SIMULATOR_UDID" ]]; then
        if ! booted_udids | ruby -e 'wanted = ARGV.fetch(0); exit($stdin.each_line.any? { |line| line.strip == wanted } ? 0 : 1)' "$SIMULATOR_UDID"; then
            echo "Simulator is not booted or available: $SIMULATOR_UDID" >&2
            return 1
        fi
        if ! candidate_container=$(xcrun simctl get_app_container "$SIMULATOR_UDID" "$BUNDLE_ID" data 2>/dev/null); then
            echo "$BUNDLE_ID is not installed on Simulator $SIMULATOR_UDID." >&2
            return 1
        fi
        RESOLVED_UDID="$SIMULATOR_UDID"
        RESOLVED_CONTAINER="$candidate_container"
        return 0
    fi

    while IFS= read -r candidate_udid; do
        [[ -n "$candidate_udid" ]] || continue
        if candidate_container=$(xcrun simctl get_app_container "$candidate_udid" "$BUNDLE_ID" data 2>/dev/null); then
            installed_udids+=("$candidate_udid")
            installed_containers+=("$candidate_container")
        fi
    done < <(booted_udids)

    if [[ ${#installed_udids[@]} -eq 0 ]]; then
        echo "No booted Simulator has $BUNDLE_ID installed." >&2
        return 1
    fi
    if [[ ${#installed_udids[@]} -gt 1 ]]; then
        echo "Multiple booted Simulators have $BUNDLE_ID installed; pass --udid." >&2
        printf '  %s\n' "${installed_udids[@]}" >&2
        return 1
    fi

    RESOLVED_UDID="${installed_udids[0]}"
    RESOLVED_CONTAINER="${installed_containers[0]}"
}

RESOLVED_UDID=""
RESOLVED_CONTAINER=""
resolve_container

if [[ ! -d "$RESOLVED_CONTAINER" || "$RESOLVED_CONTAINER" != /* ]]; then
    echo "simctl returned an invalid data-container path: $RESOLVED_CONTAINER" >&2
    exit 1
fi

MODEL_DIRECTORY="${RESOLVED_CONTAINER}/Library/Application Support/PocketLM/Models/${MODEL_DIRECTORY_NAME}"
TARGET_PATH="${MODEL_DIRECTORY}/${MODEL_INSTALLED_FILENAME}"
MANIFEST_PATH="${MODEL_DIRECTORY}/manifest.json"
MODEL_PARTIAL_PATH="${TARGET_PATH}.partial"
MANIFEST_PARTIAL_PATH="${MANIFEST_PATH}.partial"

mkdir -p -- "$MODEL_DIRECTORY"

TARGET_VALID=0
MANIFEST_VALID=0
if [[ -f "$TARGET_PATH" ]]; then
    if ruby "$VERIFIER_PATH" verify --catalog "$CATALOG_PATH" "$TARGET_PATH"; then
        TARGET_VALID=1
    elif [[ "$FORCE" -eq 0 ]]; then
        echo "Installed model is invalid; rerun with --force to replace it: $TARGET_PATH" >&2
        exit 1
    fi
fi

if [[ "$TARGET_VALID" -eq 1 && -f "$MANIFEST_PATH" ]]; then
    if ruby "$VERIFIER_PATH" verify-manifest --catalog "$CATALOG_PATH" "$MANIFEST_PATH"; then
        MANIFEST_VALID=1
    fi
fi

set_backup_exclusion() {
    local path="$1"
    mkdir -p -- "$SWIFT_CACHE_PATH"
    env CLANG_MODULE_CACHE_PATH="$SWIFT_CACHE_PATH" \
        SWIFT_MODULECACHE_PATH="$SWIFT_CACHE_PATH" \
        xcrun swift "$BACKUP_HELPER_PATH" set "$path"
}

check_backup_exclusion() {
    local path="$1"
    mkdir -p -- "$SWIFT_CACHE_PATH"
    env CLANG_MODULE_CACHE_PATH="$SWIFT_CACHE_PATH" \
        SWIFT_MODULECACHE_PATH="$SWIFT_CACHE_PATH" \
        xcrun swift "$BACKUP_HELPER_PATH" check "$path"
}

write_manifest_partial() {
    local installed_at
    installed_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    rm -f -- "$MANIFEST_PARTIAL_PATH"
    ruby "$VERIFIER_PATH" manifest \
        --catalog "$CATALOG_PATH" \
        --installed-at "$installed_at" \
        --backup-excluded \
        --output "$MANIFEST_PARTIAL_PATH"
}

if [[ "$TARGET_VALID" -eq 1 ]]; then
    if check_backup_exclusion "$TARGET_PATH" >/dev/null 2>&1 && \
       [[ "$MANIFEST_VALID" -eq 1 ]]; then
        rm -f -- "$MODEL_PARTIAL_PATH" "$MANIFEST_PARTIAL_PATH"
        echo "Using verified Simulator model: $TARGET_PATH"
        echo "Simulator: $RESOLVED_UDID"
        exit 0
    fi

    # A verified model does not need to be recopied. Repair backup exclusion or
    # its catalog-derived manifest atomically without disturbing the model.
    set_backup_exclusion "$TARGET_PATH"
    write_manifest_partial
    mv -f -- "$MANIFEST_PARTIAL_PATH" "$MANIFEST_PATH"
    ruby "$VERIFIER_PATH" verify-manifest --catalog "$CATALOG_PATH" "$MANIFEST_PATH"
    rm -f -- "$MODEL_PARTIAL_PATH"
    echo "Repaired verified Simulator model metadata: $TARGET_PATH"
    echo "Simulator: $RESOLVED_UDID"
    exit 0
fi

# Fail the capacity check before disrupting a running app. A second check just
# before the copy closes the race with other disk users.
pocketlm_require_free_space "$MODEL_DIRECTORY" "$MODEL_BYTES" "Simulator model seed"

# A new model will replace the destination. Ensure the app and therefore every
# native inference session is gone before writing or renaming model files.
TERMINATE_OUTPUT=""
if ! TERMINATE_OUTPUT=$(xcrun simctl terminate "$RESOLVED_UDID" "$BUNDLE_ID" 2>&1); then
    case "$TERMINATE_OUTPUT" in
        *"found nothing to terminate"*|*"not running"*)
            ;;
        *)
            echo "Failed to terminate $BUNDLE_ID before model replacement:" >&2
            echo "$TERMINATE_OUTPUT" >&2
            exit 1
            ;;
    esac
fi

cleanup_partials() {
    rm -f -- "$MODEL_PARTIAL_PATH" "$MANIFEST_PARTIAL_PATH"
}
trap cleanup_partials EXIT
cleanup_partials

pocketlm_require_free_space "$MODEL_DIRECTORY" "$MODEL_BYTES" "Simulator model seed"
cp "$SOURCE_PATH" "$MODEL_PARTIAL_PATH"
ruby "$VERIFIER_PATH" verify --catalog "$CATALOG_PATH" "$MODEL_PARTIAL_PATH"
set_backup_exclusion "$MODEL_PARTIAL_PATH"
write_manifest_partial

# Both files are renamed on the app-container volume. If the process stops
# between renames, the verified model remains usable and rerunning repairs the
# missing or stale manifest without another 491 MB copy.
mv -f -- "$MODEL_PARTIAL_PATH" "$TARGET_PATH"
ruby "$VERIFIER_PATH" verify --catalog "$CATALOG_PATH" "$TARGET_PATH"
mv -f -- "$MANIFEST_PARTIAL_PATH" "$MANIFEST_PATH"
ruby "$VERIFIER_PATH" verify-manifest --catalog "$CATALOG_PATH" "$MANIFEST_PATH"
check_backup_exclusion "$TARGET_PATH" >/dev/null

trap - EXIT
echo "Seeded verified Simulator model: $TARGET_PATH"
echo "Manifest: $MANIFEST_PATH"
echo "Simulator: $RESOLVED_UDID"
