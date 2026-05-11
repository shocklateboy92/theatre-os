#!/bin/sh
# tests/run.sh — theatre-os end-to-end test harness.
#
# Boots a fresh VM (auto-builds if needed), runs each case under
# tests/cases/ in sequence, and reports pass/fail. Cases run against
# a SHARED VM with cleanup between them — see tests/lib.sh
# `cleanup_persist` — to keep the harness fast (one boot, ~30s
# instead of three).
#
# Cases that mutate persistent state (restore, experiment) reboot the
# VM as part of their flow; the harness's `vm_wait` re-establishes
# SSH after each reboot.
#
# Usage:
#   ./tests/run.sh                  run all cases
#   ./tests/run.sh 02-restore       run a single case
#
# Exit status: 0 if all cases pass, 1 otherwise.

set -eu

cd "$(dirname "$0")/.."   # repo root

# shellcheck source=tests/lib.sh
. tests/lib.sh

# --- Build (if needed) ----------------------------------------------

CURRENT_VERSION=$(./mkosi.version)
if [ ! -f "mkosi.output/theatre-os_${CURRENT_VERSION}.raw" ]; then
    log "no .raw for version $CURRENT_VERSION, building"
    ./build.sh
    # mkosi.version is time-based and is re-evaluated by build.sh, so
    # the version we just built may differ from CURRENT_VERSION above.
    # Re-derive from the newest SHA256SUMS on disk.
    CURRENT_VERSION=$(ls -t mkosi.output/theatre-os_*.SHA256SUMS \
        | head -1 \
        | grep -oE '2026-[0-9-]+')
    log "built version: $CURRENT_VERSION"
else
    log "using existing build: $CURRENT_VERSION"
fi

# --- Setup -----------------------------------------------------------

VM_LOG=$(mktemp -t theatre-os-vm.XXXXXX.log)
TOTAL_CASES=0
FAILED_CASES=0

# Always kill the VM and clean up the log on exit, even on errors.
trap 'vm_kill; rm -f "$VM_LOG"' EXIT INT TERM

# --- Boot once for all cases ----------------------------------------

vm_start "$CURRENT_VERSION"
vm_wait

# --- Run cases ------------------------------------------------------

# If args were given, run only those cases. Otherwise all cases in
# lexicographic order.
if [ "$#" -gt 0 ]; then
    case_files=""
    for c in "$@"; do
        case_files="$case_files tests/cases/${c}.sh"
    done
else
    case_files=$(ls tests/cases/*.sh)
fi

for case_file in $case_files; do
    [ -f "$case_file" ] || { log "missing case: $case_file"; FAILED_CASES=$((FAILED_CASES+1)); continue; }
    case_name=$(basename "$case_file" .sh)
    TOTAL_CASES=$((TOTAL_CASES+1))

    printf '\n=== %s ===\n' "$case_name" >&2

    # Each case runs in a subshell so an exit 1 doesn't kill the
    # harness. CASE_FAILED is set by fail() in lib.sh.
    (
        set -eu
        # shellcheck source=tests/lib.sh
        . tests/lib.sh
        CASE_FAILED=0
        # shellcheck source=/dev/null
        . "$case_file"
        exit "$CASE_FAILED"
    ) || FAILED_CASES=$((FAILED_CASES+1))

    # Reset persist state for the next case. Skipped after the LAST
    # case because there's no "next" and skipping saves a few seconds.
    if [ "$case_file" != "$(echo "$case_files" | awk '{print $NF}')" ]; then
        cleanup_persist
    fi
done

# --- Summary --------------------------------------------------------

printf '\n' >&2
if [ "$FAILED_CASES" -eq 0 ]; then
    log "all $TOTAL_CASES case(s) passed"
    exit 0
else
    log "$FAILED_CASES of $TOTAL_CASES case(s) FAILED"
    exit 1
fi
