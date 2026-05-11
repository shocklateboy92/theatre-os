#!/bin/sh
# vacuum.sh — keep only the last N versions on dufs, delete the rest.
#
# Cheap insurance: without this, dufs accumulates artefacts forever. Run
# ad-hoc, not as part of every publish (different blast radius — publish
# is fast and idempotent, vacuum is destructive).
#
# Default N=20 = 2x the on-box InstancesMax (10 in the .transfer files).
# Server keeps history slightly longer than any one box so a box that's
# been off for a while can still find an intermediate version.
#
# Order: delete artefacts first, then rewrite SHA256SUMS. If interrupted
# between the two, consumers see SHA256SUMS pointing at deleted files —
# sysupdate retries cleanly. Reverse order would leave orphan files
# referenced by no checksum; harmless but messier.

set -eu

N="${1:-20}"
PUSH="https://push.apps.lasath.com/theatre-t480"
PULL="https://static.apps.lasath.com/sysupdate/theatre-t480"

# Discover all known versions from the upstream SHA256SUMS (one source
# of truth — anything not listed there is invisible to consumers anyway).
versions=$(
    curl -fsS "$PULL/SHA256SUMS" \
        | awk '{print $2}' \
        | grep -oE 'theatre-os_[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{4}' \
        | sort -u
)

total=$(printf '%s\n' "$versions" | grep -c . || true)
if [ "$total" -le "$N" ]; then
    printf 'vacuum: %d versions <= N=%d, nothing to do\n' "$total" "$N"
    exit 0
fi

# head -n -N: drop the newest N from the list, leaving the oldest to delete.
to_delete=$(printf '%s\n' "$versions" | head -n "-$N")
keep=$(printf '%s\n' "$versions" | tail -n "$N")

printf '\n>>> Deleting %d old versions (keeping last %d):\n' \
    "$(printf '%s\n' "$to_delete" | wc -l)" "$N"
printf '%s\n' "$to_delete"

for v in $to_delete; do
    for ext in tar efi; do
        echo "    DELETE $v.$ext"
        # || true: 404 from a previous half-vacuum is fine
        curl -fsS -X DELETE "$PUSH/$v.$ext" || true
    done
done

# Rewrite SHA256SUMS with only the kept versions. Build a single regex
# alternation so we hit grep once rather than per-version.
keep_pat=$(printf '%s\n' "$keep" | paste -sd'|' -)
TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT
curl -fsS "$PULL/SHA256SUMS" \
    | grep -E "($keep_pat)" \
    > "$TMP"

echo ">>> PUT SHA256SUMS (vacuumed)"
curl -fT "$TMP" "$PUSH/SHA256SUMS"

echo "Vacuum complete"
