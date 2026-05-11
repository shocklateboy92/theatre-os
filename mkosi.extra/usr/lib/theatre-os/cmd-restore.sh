# theatre-os restore — stage a persist snapshot to be the active
# persist after the next boot.
#
# Uses the same btrfs swap-snapshot trick as experiment mode:
# subvolume mounts are inode-tracked, so renaming a subvol doesn't
# disturb a live mount. From the running system:
#
#   1. Rename current @persist/<v> → @persist/<v>-pre-restore-<ts>
#      (the live mount keeps using it under the new name).
#   2. Snapshot the chosen @persist/<v>-snap-<id> → fresh
#      @persist/<v> (RW, sitting on disk, unmounted).
#   3. Reboot. The initrd mounts the fresh @persist/<v> and we're on
#      the restored state. The renamed @persist/<v>-pre-restore-<ts>
#      stays around as an undo-of-the-undo.
#
# Caveat (from README): between running `theatre-os restore` and
# rebooting, the live system is still on the OLD (renamed) persist.
# Writes during that window land in -pre-restore-<ts> and won't
# appear on the restored state. We prompt to reboot immediately to
# minimise that window.
#
# This intentionally only touches @persist (not @os). The OS at
# /, /usr, /etc stays as it is — we're just rewinding userdata.
# To roll back the OS, pick an older entry from the systemd-boot
# menu (which auto-selects the matching @persist/<v> for that OS
# version anyway, so OS rollback also rewinds persist; this command
# is for when you want to rewind WITHIN the running OS version).

cmd_restore() {
    [ "$#" -eq 1 ] || die "restore requires exactly one snapshot id"
    snap=$(resolve_snapshot "$1")

    if is_experiment_mode; then
        die "refusing to restore from experiment mode (reboot to leave first)"
    fi

    running=$(running_version)
    persist_dir="$THEATRE_DATA/@persist/$running"
    snap_dir="$THEATRE_DATA/@persist/$snap"

    [ -d "$snap_dir" ] || die "snapshot subvol missing: $snap_dir"
    [ -d "$persist_dir" ] || die "running persist subvol missing: $persist_dir (something is very wrong)"

    ts=$(date -u +%Y-%m-%d-%H%M)
    backup="@persist/${running}-pre-restore-${ts}"
    backup_dir="$THEATRE_DATA/$backup"
    if [ -e "$backup_dir" ]; then
        die "backup target already exists: $backup_dir (timestamp collision; wait a minute)"
    fi

    cat <<EOF
About to restore @persist/$snap to be the next boot's @persist/$running.

  Steps:
    1. Rename current @persist/$running → $backup
       (live mount keeps using it; writes during this window will
       land in $backup and NOT appear on the restored state)
    2. Snapshot @persist/$snap → @persist/$running
    3. Recommend immediate reboot

  After reboot:
    - The restored state is active.
    - Roll back this restore by booting an older UKI from systemd-boot
      (which would pick a different @persist/<other-v> entirely), or
      by running `theatre-os restore` against $backup.

EOF
    if ! confirm "Proceed?"; then
        echo "Aborted."
        return 1
    fi

    # Step 1: rename. Inode-tracked mount means /system/persist and
    # /var stay attached to the same data; the path the kernel knows
    # them by changes underneath.
    printf '\n>>> mv @persist/%s %s\n' "$running" "$backup"
    mv "$persist_dir" "$backup_dir"

    # Step 2: snapshot. RW (default) since the running system will
    # mount it RW after reboot.
    printf '>>> btrfs subvolume snapshot @persist/%s @persist/%s\n' "$snap" "$running"
    if ! btrfs subvolume snapshot "$snap_dir" "$persist_dir"; then
        # Roll back the rename so we're back on a working persist.
        printf '\n!!! snapshot failed; rolling back rename\n' >&2
        mv "$backup_dir" "$persist_dir"
        die "restore failed at snapshot step (rolled back)"
    fi

    cat <<EOF

Restore staged. Next boot will use @persist/$snap (via fresh
@persist/$running snapshotted from it).

>>> WARNING: this system is still running on the OLD persist
>>> (now @persist/$running-pre-restore-$ts). Any writes between now
>>> and reboot will be LOST on the restored state. Reboot soon.

EOF
    if confirm "Reboot now?"; then
        systemctl reboot
    fi
}
