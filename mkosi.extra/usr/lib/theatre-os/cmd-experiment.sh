# theatre-os experiment — enter experiment mode live, no reboot.
#
# For when you need to `pacman -S foo` on the box to test something
# before committing it to mkosi config. Common use case: discovering
# hardware-specific tweaks on the T480 (BT/WOL/power-key etc.) where
# we don't yet know the right config and need to iterate.
#
# Mechanics: btrfs subvolume mounts are inode-tracked (the kernel
# resolves the subvol object once at mount time and follows it
# regardless of path renames). Validated experimentally — see the
# README's "needs prototyping" caveat, which has now been answered:
# yes, the dance works.
#
# For each of @os/<v> and @persist/<v>:
#   1. mv <subvol> <subvol>-experiment-<u>
#      Live mount stays attached to the same subvol object under
#      its new name.
#   2. btrfs subvolume snapshot <subvol>-experiment-<u> <subvol>
#      Fresh snapshot at the original path, sitting on disk
#      unmounted, ready for the next normal boot.
#      For @os: snapshot RO (next boot mounts RO).
#      For @persist: snapshot RW (next boot mounts RW; persist is
#                    always RW by design).
# For @os only:
#   3. btrfs property set <subvol>-experiment-<u> ro false
#   4. mount -o remount,rw /
#      Now / is writable. /usr/, /etc/ etc. accept writes — they
#      land in the renamed subvol the kernel still has open, NOT in
#      the fresh snapshot at the original path.
#
# To leave experiment mode: reboot. Next boot sees the fresh
# @os/<v> and @persist/<v> snapshots and resumes normal mode. The
# -experiment-<u> subvols stay on disk for forensic browsing (last
# few kept; older auto-GC'd at next experiment-on).
#
# A motd is written to advertise experiment mode to anyone SSHing
# in. Removed at... well, never; on next reboot the entire @os/<v>
# is replaced by the fresh snapshot which doesn't have the motd.

# How many old experiment subvols to keep on disk for forensic
# browsing. Older than this get GC'd at next experiment-on. CoW
# means each one costs only the delta from when it was created
# until the next reboot, so 10 is cheap.
THEATRE_EXPERIMENT_RETENTION=10

# Detect old experiment subvols (under either @os or @persist).
list_experiments() {
    container=$1   # @os or @persist
    list_versions "$container" | grep -E -- '-experiment-' || true
}

cmd_experiment() {
    if is_experiment_mode; then
        die "already in experiment mode (reboot to leave)"
    fi

    running=$(running_version)
    # Unique tag — UTC timestamp at minute resolution. Same format
    # we use for snapshots; sortable, human-readable, distinguishes
    # "the experiment from this morning" from "the one from last
    # week" at a glance via systemd-boot menu / btrfs subvol list.
    u=$(date -u +%Y-%m-%d-%H%M)

    cat <<EOF
About to enter experiment mode.

  - / will be mounted RW; /usr, /etc edits will start succeeding.
  - All writes (to / AND /var, /home/kodi, etc.) land in throwaway
    -experiment-${u} subvols and VANISH on next reboot.
  - To leave: \`systemctl reboot\`.
  - To keep changes: edit mkosi.extra/ in the theatre-os repo on
    your dev box and ship a new image (the iteration loop).

EOF
    if ! confirm "Proceed?"; then
        echo "Aborted."
        return 1
    fi

    # GC old experiment subvols beyond retention. We do this BEFORE
    # the new ones so a failed experiment-on doesn't lose old
    # forensic data.
    gc_experiments

    # Step 1+2: rename + snapshot back, for both @os and @persist.
    # Order matters slightly: do the rename+snapshot atomically per
    # container so a failure mid-way leaves a recoverable state.
    swap_subvol @os "$running" "$u" -r   # @os/<v>: snapshot RO for next boot
    if ! swap_subvol @persist "$running" "$u"; then
        # @persist swap failed; try to roll back the @os swap so
        # we're not in a half-experiment state.
        printf '\n!!! @persist swap failed; rolling back @os swap\n' >&2
        rollback_swap @os "$running" "$u"
        die "experiment-on failed at @persist; rolled back @os"
    fi

    # Step 3+4: flip the @os experiment subvol RW and remount /.
    # Already validated that this works for live /. If it fails the
    # subvol swap is already done; reboot recovers cleanly.
    printf '\n>>> btrfs property set @os/%s-experiment-%s ro false\n' "$running" "$u"
    btrfs property set "$THEATRE_DATA/@os/${running}-experiment-${u}" ro false

    printf '>>> mount -o remount,rw /\n'
    mount -o remount,rw /

    # Drop the motd advertising experiment mode. /etc is now
    # writable thanks to the remount. Cleared automatically on
    # reboot because we're writing to the throwaway subvol.
    write_motd "$u"

    cat <<EOF

EXPERIMENT MODE ACTIVE.
  - Subvols: @os/${running}-experiment-${u}, @persist/${running}-experiment-${u}
  - Reboot to leave.

EOF
}

# Atomic rename + fresh-snapshot. Args: container, version, unique tag,
# [extra args to btrfs subvolume snapshot — e.g. -r for RO]
swap_subvol() {
    container=$1; v=$2; u=$3; shift 3
    src="$THEATRE_DATA/$container/$v"
    exp="$THEATRE_DATA/$container/${v}-experiment-${u}"

    [ -d "$src" ] || die "missing $src"
    [ -e "$exp" ] && die "experiment subvol already exists: $exp"

    printf '\n>>> mv %s/%s %s/%s-experiment-%s\n' "$container" "$v" "$container" "$v" "$u"
    mv "$src" "$exp"

    printf '>>> btrfs subvolume snapshot %s%s/%s-experiment-%s %s/%s\n' \
        "$([ "$#" -gt 0 ] && printf '%s ' "$@")" \
        "$container" "$v" "$u" "$container" "$v"
    if ! btrfs subvolume snapshot "$@" "$exp" "$src"; then
        # Rollback the rename.
        mv "$exp" "$src"
        return 1
    fi
}

# Undo a successful swap_subvol — used for cross-container rollback.
rollback_swap() {
    container=$1; v=$2; u=$3
    src="$THEATRE_DATA/$container/$v"
    exp="$THEATRE_DATA/$container/${v}-experiment-${u}"
    btrfs subvolume delete "$src" || true
    mv "$exp" "$src"
}

# GC: delete experiment subvols older than the retention limit.
# Counted independently per container; oldest first.
gc_experiments() {
    for container in @os @persist; do
        all=$(list_experiments "$container" | sort)
        count=$(printf '%s\n' "$all" | grep -c . || true)
        if [ "$count" -le "$THEATRE_EXPERIMENT_RETENTION" ]; then
            continue
        fi
        # Drop the N oldest, keep the retention-limit newest.
        to_drop_count=$((count - THEATRE_EXPERIMENT_RETENTION))
        printf '%s\n' "$all" | head -n "$to_drop_count" | while read -r name; do
            printf '>>> GC %s/%s (older than retention=%d)\n' "$container" "$name" "$THEATRE_EXPERIMENT_RETENTION"
            btrfs subvolume delete "$THEATRE_DATA/$container/$name" || true
        done
    done
}

# Drop a motd advertising experiment mode. Not super pretty; conveys
# the essentials. Cleared automatically on reboot (writes go to the
# throwaway subvol).
write_motd() {
    u=$1
    cat > /etc/motd <<EOF

  ╔═════════════════════════════════════════════════╗
  ║                                                 ║
  ║   theatre-os EXPERIMENT MODE                    ║
  ║                                                 ║
  ║   /, /var, /home/kodi are throwaway.            ║
  ║   All writes vanish on \`systemctl reboot\`.      ║
  ║                                                 ║
  ║   Tag: $u                              ║
  ║                                                 ║
  ║   To keep changes: edit mkosi config in the     ║
  ║   theatre-os repo and ship a new image.         ║
  ║                                                 ║
  ╚═════════════════════════════════════════════════╝

EOF
    # Also log to journal for forensic trail.
    logger -t theatre-os -p user.notice \
        "entered experiment mode (tag $u, root subvol @os/${running}-experiment-${u})"
}
