#!/bin/sh
# prune.sh — trim old build artefacts from mkosi.output/.
#
# Each build produces ~11 GiB (.raw + .tar + .efi + .SHA256SUMS) and,
# because the version stamp is date-based, every build lands under a new
# name and they accumulate. mkosi has no built-in output retention, so
# this is a manual housekeeping step (run it when the disk gets tight) —
# it deliberately lives OUTSIDE the build path so a build never silently
# deletes a previous artefact.
#
# Keeps the most recent N builds (default 2) so the last known-good .raw
# is still around to compare against or fall back to. Date-based version
# stamps sort lexicographically as time order, so `sort` puts oldest
# first and we drop everything but the newest N.
#
# Usage:
#   ./prune.sh            keep the newest 2 builds
#   ./prune.sh 5          keep the newest 5

set -eu

cd "$(dirname "$0")"

OUTDIR="mkosi.output"
RETAIN="${1:-2}"

case "$RETAIN" in
    ''|*[!0-9]*) echo "prune.sh: retain count must be a positive integer" >&2; exit 1 ;;
esac
[ "$RETAIN" -ge 1 ] || { echo "prune.sh: retain count must be >= 1" >&2; exit 1; }

# All built versions (from the SHA256SUMS filenames), oldest first.
existing=$(ls "$OUTDIR"/theatre-os_*.SHA256SUMS 2>/dev/null \
    | sed 's|.*/theatre-os_\(.*\)\.SHA256SUMS|\1|' \
    | sort -u)

to_drop=$(printf '%s\n' "$existing" | head -n "-$RETAIN" || true)

if [ -z "$to_drop" ]; then
    echo "prune.sh: nothing to prune (keeping newest $RETAIN)"
    exit 0
fi

for v in $to_drop; do
    [ -n "$v" ] || continue
    echo "prune.sh: pruning $OUTDIR/theatre-os_$v.*"
    sudo rm -f "$OUTDIR"/theatre-os_"$v".raw \
               "$OUTDIR"/theatre-os_"$v".tar \
               "$OUTDIR"/theatre-os_"$v".efi \
               "$OUTDIR"/theatre-os_"$v".SHA256SUMS \
               "$OUTDIR"/theatre-os_"$v"
done
