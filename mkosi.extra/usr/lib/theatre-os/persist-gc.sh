#!/bin/bash
# theatre-os persist GC — delete orphan @persist/<v> subvolumes whose
# matching @os/<v> no longer exists.
#
# Runs late in every boot via theatre-os-persist-gc.service (off the
# critical path — nothing waits on it). Running it at boot is
# path-independent: it cleans up no matter how the update that orphaned
# a @persist was triggered (updatectl on demand, or the timer).
#
# Why orphans happen: sysupdate's InstancesMax sweep deletes old
# @os/<v> subvols, but it knows nothing about @persist — so the paired
# @persist/<v> is left behind. We reap it here.
#
# IMPORTANT — only bare version subvols are eligible. @persist also
# holds, as sibling subvolumes:
#   - manual snapshots   @persist/<v>-snap-<ts>[-<name>]
#   - restore backups    @persist/<v>-pre-restore-<ts>
#   - experiment scratch @persist/<v>-experiment-<u>
# None of these have a matching @os/<v> of the same name, so a naive
# "in @persist but not in @os" set-difference would wrongly delete them
# all. We match ONLY names that are a bare version stamp —
# YYYY-MM-DD-HHMM with nothing appended — and leave everything else to
# its own lifecycle (`theatre-os snapshot prune`, experiment retention,
# etc.).

set -eu

LIB=/usr/lib/theatre-os
# shellcheck source=/dev/null
. "$LIB/lib.sh"

log() { printf 'theatre-os-persist-gc: %s\n' "$*"; }

# Bare version stamp: exactly YYYY-MM-DD-HHMM, anchored, nothing else.
# Same shape as ./mkosi.version. Anchoring is what excludes
# <v>-snap-*, <v>-experiment-*, <v>-pre-restore-* (they have a suffix).
BARE_VERSION_RE='^[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{4}$'

running=$(running_version)

# Bare @os versions currently on disk (the keep-set).
os_versions=$(list_versions @os | grep -E "$BARE_VERSION_RE" || true)

# Safety: the running version's own @os/<v> must exist, so a non-empty
# keep-set is invariant. An empty one means list_versions/the data
# mount is broken — refuse rather than treat every @persist as an
# orphan and wipe them all.
if [ -z "$os_versions" ]; then
    log "ERROR: no @os versions found (data partition not mounted?); refusing to GC"
    exit 1
fi

# Bare @persist versions — the only GC candidates.
persist_versions=$(list_versions @persist | grep -E "$BARE_VERSION_RE" || true)

deleted=0
for v in $persist_versions; do
    # Never touch the running version's persist (belt-and-braces: its
    # @os exists by definition, so it can't be an orphan anyway).
    [ "$v" = "$running" ] && continue

    # Orphan iff no @os/<v> of the same name exists.
    if printf '%s\n' "$os_versions" | grep -qx -- "$v"; then
        continue
    fi

    log "deleting orphan @persist/$v (no matching @os/$v)"
    if btrfs subvolume delete "$THEATRE_DATA/@persist/$v"; then
        deleted=$((deleted + 1))
    else
        log "WARNING: failed to delete @persist/$v (continuing)"
    fi
done

if [ "$deleted" -eq 0 ]; then
    log "no orphan @persist subvolumes"
else
    log "deleted $deleted orphan @persist subvolume(s)"
fi
