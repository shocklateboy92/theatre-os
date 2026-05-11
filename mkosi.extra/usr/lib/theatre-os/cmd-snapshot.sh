# theatre-os snapshot — manual persist snapshots for explicit
# checkpoints before risky persist mutations (e.g. ha-config's
# deploy.sh pushing new Kodi addons, manual SSH edits to Kodi
# settings, library imports). Complementary to:
#   - The auto per-version persist snapshot taken by `theatre-os update`
#     (one fork per OS install — coarse, doesn't help mid-version).
#   - Experiment mode (throwaway scratch for /usr / /etc writes —
#     different scope, both @os and @persist snapshotted at boot).
#
# Sub-verbs:
#   theatre-os snapshot [name]              take a snapshot
#   theatre-os snapshot list                show snapshots
#   theatre-os snapshot delete <id>         drop one
#   theatre-os snapshot prune               drop snapshots > 30 days, with confirm
#
# Snapshot naming: @persist/<v>-snap-<UTC-timestamp>[-<name>]
#   <v>         = running version (so snapshots are tagged with the OS
#                 version at snapshot time — useful for restore semantics)
#   <timestamp> = UTC, minute resolution, sortable: 2026-05-11-1430
#   <name>      = optional human-readable suffix; restricted to
#                 [a-zA-Z0-9_-] to keep parsing trivial.
#
# Snapshots are RW (default for `btrfs subvolume snapshot`) but only
# read by `theatre-os restore` to seed a fresh @persist/<v>. They're
# never directly mounted, so RW vs RO doesn't matter at use time.

# Where snapshots live and how their names parse.
THEATRE_SNAPSHOT_PREFIX="-snap-"
# Strict timestamp regex: YYYY-MM-DD-HHMM. Sorts lexicographically as
# date order. Matches ./mkosi.version.
THEATRE_SNAPSHOT_TS_RE='[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{4}'
# Optional human suffix: alphanumeric + underscore + hyphen.
THEATRE_SNAPSHOT_NAME_RE='[a-zA-Z0-9_-]+'

# List manual-snapshot subvol names (without the @persist/ prefix).
# Filters out the per-version base subvols (@persist/<v>) — those are
# managed by `theatre-os update`, not by this command.
list_snapshots() {
    # `--` so grep doesn't interpret the leading `-` of the pattern
    # ("-snap-...") as a command-line flag.
    list_versions @persist | grep -E -- "${THEATRE_SNAPSHOT_PREFIX}${THEATRE_SNAPSHOT_TS_RE}" || true
}

# Resolve a user-supplied id to a full snapshot subvol name. The id
# can be a full subvol name, a timestamp, or a name suffix. Ambiguity
# is fatal (refuses to guess).
resolve_snapshot() {
    id=$1
    matches=$(list_snapshots | grep -F -- "$id" || true)
    count=$(printf '%s\n' "$matches" | grep -c . || true)
    case "$count" in
        0) die "no snapshot matching '$id'" ;;
        1) printf '%s' "$matches" ;;
        *) printf 'theatre-os: ambiguous snapshot id %s, matches:\n' "$id" >&2
           printf '  %s\n' $matches >&2
           exit 1
           ;;
    esac
}

# Take a snapshot.
cmd_snapshot_take() {
    name=${1:-}
    if [ -n "$name" ] && ! printf '%s' "$name" | grep -qE "^${THEATRE_SNAPSHOT_NAME_RE}\$"; then
        die "snapshot name must match [a-zA-Z0-9_-]+ (got: $name)"
    fi

    # Refuse from experiment mode. running_version() reads
    # IMAGE_VERSION from /usr/lib/os-release, which was baked at
    # image build time and is unaware of the experiment-mode rename.
    # So we'd snapshot @persist/<v> (the pristine fresh-for-next-boot
    # subvol), NOT @persist/<v>-experiment-<u> (what we're actually
    # mutating). The result would be a silently-wrong snapshot
    # capturing pristine state with a misleading name, and the
    # in-experiment mutations would only exist in the throwaway
    # forensic subvol.
    #
    # The principled position: experiment mode is for throwaway
    # testing. To keep changes, edit mkosi.extra/ in the repo and
    # ship a new image (the iteration loop). If you want to
    # checkpoint persist for restore-later, do it BEFORE entering
    # experiment mode.
    if is_experiment_mode; then
        die "refusing to snapshot from experiment mode (would capture pristine state, not your in-experiment changes; reboot to leave first)"
    fi

    running=$(running_version)
    ts=$(date -u +%Y-%m-%d-%H%M)
    base="${running}${THEATRE_SNAPSHOT_PREFIX}${ts}"
    if [ -n "$name" ]; then
        snap="${base}-${name}"
    else
        snap="$base"
    fi

    if [ -d "$THEATRE_DATA/@persist/$snap" ]; then
        die "snapshot already exists: @persist/$snap (timestamps have minute resolution; wait a minute)"
    fi

    printf '>>> btrfs subvolume snapshot @persist/%s @persist/%s\n' "$running" "$snap"
    btrfs subvolume snapshot \
        "$THEATRE_DATA/@persist/$running" \
        "$THEATRE_DATA/@persist/$snap"

    printf '\nTook snapshot @persist/%s\n' "$snap"
    printf 'Restore with: theatre-os restore %s\n' "$snap"
}

# List snapshots, oldest first. Intentionally light on formatting —
# the user can pipe to column(1) if they want a table. We don't show
# on-disk delta sizes because btrfs qgroups (the only way to get them)
# aren't enabled by default and have meaningful write-time overhead;
# we'd rather not pay it for a verb that runs maybe weekly.
cmd_snapshot_list() {
    snaps=$(list_snapshots)
    if [ -z "$snaps" ]; then
        echo "No manual snapshots."
        return 0
    fi
    printf '%s\n' "$snaps"
}

# Delete a snapshot by id (full name, timestamp, or name suffix).
cmd_snapshot_delete() {
    [ "$#" -eq 1 ] || die "snapshot delete requires exactly one id"
    snap=$(resolve_snapshot "$1")
    printf '>>> btrfs subvolume delete @persist/%s\n' "$snap"
    btrfs subvolume delete "$THEATRE_DATA/@persist/$snap"
}

# Drop snapshots older than 30 days. Confirms before deleting.
cmd_snapshot_prune() {
    cutoff=$(date -u -d '30 days ago' +%Y-%m-%d-%H%M 2>/dev/null) \
        || die "date -d not available; install GNU coreutils"

    snaps=$(list_snapshots)
    [ -n "$snaps" ] || { echo "No snapshots to prune."; return 0; }

    # Extract the timestamp from each snap name and compare
    # lexicographically (YYYY-MM-DD-HHMM sorts as date order). The
    # snap name contains TWO timestamps (the running version baked in
    # at snapshot time + the snapshot's own timestamp); we want the
    # second one, after the "-snap-" marker.
    to_delete=$(printf '%s\n' "$snaps" | while read -r s; do
        ts=$(printf '%s' "$s" \
            | sed -nE "s|.*${THEATRE_SNAPSHOT_PREFIX}(${THEATRE_SNAPSHOT_TS_RE}).*|\\1|p")
        # Belt-and-braces: skip if we couldn't parse a timestamp.
        [ -n "$ts" ] || continue
        if [ "$ts" \< "$cutoff" ]; then
            printf '%s\n' "$s"
        fi
    done)

    if [ -z "$to_delete" ]; then
        echo "Nothing older than 30 days."
        return 0
    fi

    printf 'About to delete %d snapshot(s) older than %s:\n' \
        "$(printf '%s\n' "$to_delete" | wc -l)" "$cutoff"
    printf '  %s\n' $to_delete

    if ! confirm "Proceed?"; then
        echo "Aborted."
        return 1
    fi

    for s in $to_delete; do
        btrfs subvolume delete "$THEATRE_DATA/@persist/$s"
    done
}

# Sub-verb dispatcher. Called from theatre-os bin's `snapshot` arm.
cmd_snapshot() {
    sub=${1:-take}
    [ "$#" -gt 0 ] && shift || true
    case "$sub" in
        list)   cmd_snapshot_list "$@"   ;;
        delete) cmd_snapshot_delete "$@" ;;
        prune)  cmd_snapshot_prune "$@"  ;;
        # Anything else is a snapshot name (or no arg = unnamed snapshot).
        *)      cmd_snapshot_take "$sub" ;;
    esac
}
