# theatre-os update — pull and install the next release.
#
# Wraps systemd-sysupdate to add the experiment-mode guard and the
# per-version persist snapshot. The CLI is the only entry point;
# systemd-sysupdated and its timer are masked at image build time so
# nothing else can drive sysupdate (see README → theatre-os update).
#
# Flow:
#   1. Refuse if running in experiment mode (would fork @persist from an
#      ephemeral state that won't exist after the next reboot).
#   2. Snapshot the on-disk subvol list before sysupdate runs so we can
#      identify which @os/<n> it just created.
#   3. Run systemd-sysupdate. It downloads .tar+.efi, extracts the rootfs
#      into a fresh @os/<n>, drops the UKI in the ESP, and GCs old @os/<x>
#      per InstancesMax in the transfer files.
#   4. Diff the @os subvol list to discover <n>, snapshot @persist/<r> →
#      @persist/<n> so the new boot has its own forked persist state.
#   5. GC orphan @persist/<x> where @os/<x> is no longer present (sysupdate
#      doesn't know about persist subvols, so we run our own paired GC).
#   6. Offer to reboot.

cmd_update() {
    # --reboot / --no-reboot make the post-update reboot non-interactive,
    # for ssh sessions where you'd rather not bother answering the prompt
    # (or where stdin isn't a tty and `confirm` would refuse). Default
    # behaviour with neither flag is to prompt with [Y/n] — Enter reboots,
    # since that's what the user wants ~all the time.
    reboot_mode=ask
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --reboot)    reboot_mode=yes; shift ;;
            --no-reboot) reboot_mode=no; shift ;;
            *) die "update: unknown argument: $1" ;;
        esac
    done

    if is_experiment_mode; then
        die "refusing to update from experiment mode (reboot to leave experiment mode first)"
    fi

    running=$(running_version)
    printf 'Running version: %s\n' "$running"

    # Snapshot which @os subvols exist before sysupdate so we can identify
    # the new one by set difference. More robust than parsing sysupdate's
    # human-readable stdout.
    before=$(list_versions @os)

    printf '\n>>> systemd-sysupdate update --verify=no\n'
    # --verify=no skips the GPG-signature step only; SHA256 hashes from
    # SHA256SUMS are still checked unconditionally per sysupdate.d(5).
    # See README → Architecture → Distribution for the no-signing
    # rationale (single LAN trust boundary).
    /usr/lib/systemd/systemd-sysupdate --verify=no update

    after=$(list_versions @os)
    new=$(printf '%s\n%s\n' "$before" "$after" | sort | uniq -u | head -n1)

    if [ -z "$new" ]; then
        printf '\nNo new @os subvolume created (already up to date).\n'
        return 0
    fi
    printf '\nInstalled @os/%s\n' "$new"

    # Snapshot persist <r> -> <n>. Has to be RW (default for snapshot).
    if [ -d "$THEATRE_DATA/@persist/$new" ]; then
        printf '@persist/%s already exists, leaving as-is\n' "$new"
    else
        printf '\n>>> btrfs subvolume snapshot @persist/%s @persist/%s\n' "$running" "$new"
        btrfs subvolume snapshot \
            "$THEATRE_DATA/@persist/$running" \
            "$THEATRE_DATA/@persist/$new"
    fi

    # GC orphan @persist subvols (any @persist/<x> with no matching @os/<x>).
    # sysupdate did its own InstancesMax GC on @os, so the survivors here
    # are the ones we should keep persist for.
    os_versions=$(list_versions @os)
    persist_versions=$(list_versions @persist)
    orphans=$(printf '%s\n%s\n%s\n' "$os_versions" "$os_versions" "$persist_versions" \
        | sort | uniq -u)
    if [ -n "$orphans" ]; then
        printf '\n>>> GCing orphan @persist subvolumes:\n'
        printf '%s\n' "$orphans"
        for v in $orphans; do
            btrfs subvolume delete "$THEATRE_DATA/@persist/$v"
        done
    fi

    printf '\nUpdate complete. Reboot to use %s.\n' "$new"
    case "$reboot_mode" in
        yes) systemctl reboot ;;
        no)  printf 'Skipping reboot (--no-reboot).\n' ;;
        ask) if confirm "Reboot now?" Y; then systemctl reboot; fi ;;
    esac
}
