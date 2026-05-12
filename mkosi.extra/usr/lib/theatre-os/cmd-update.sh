# shellcheck shell=bash
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
#   2. Ask sysupdate (check-new --json) what version is available. If none,
#      bail out clean.
#   3. PRE-SNAPSHOT: btrfs subvolume snapshot @persist/<running> →
#      @persist/<target>. Done BEFORE the install for a deliberate
#      reason: if anything in the rest of the transaction fails, an
#      orphan @persist subvol is harmless (it'll be GC'd next run),
#      but an orphan @os subvol with no matching @persist is *fatal*
#      — initrd's sysroot-system-persist.mount fails, switch-root
#      never happens, the box drops to emergency. Pre-snapshotting
#      biases failure modes toward the recoverable side. (See the
#      one-time persist-snapshot bug fixed by switching from a
#      `before/after uniq -u` set-difference on @os to a pinned
#      target version.)
#   4. Run systemd-sysupdate update <target>. Pinning the version
#      means if upstream publishes a *newer* version between our
#      check-new and our update calls, sysupdate fails loudly rather
#      than silently installing a different version than the one we
#      pre-snapshotted persist for.
#   5. GC orphan @persist/<x> where @os/<x> is no longer present
#      (sysupdate doesn't know about persist subvols, so we run our
#      own paired GC). This also cleans up the pre-snapshot we
#      created in step 3 if step 4 failed.
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

    # Ask sysupdate what's available remotely. --verify=no because we
    # don't sign artefacts (LAN trust boundary; SHA256SUMS is checked
    # unconditionally either way — see README → Architecture →
    # Distribution). --json=short emits a single line of JSON we
    # can pipe to jq.
    #
    # check-new prints progress lines (HTTP fetch etc.) to stderr and
    # the JSON object to stdout, so capturing stdout cleanly works
    # without grep heroics.
    printf '\n>>> systemd-sysupdate --verify=no check-new --json=short\n'
    target=$(/usr/lib/systemd/systemd-sysupdate --verify=no check-new --json=short \
        | jq -r .available)

    if [ -z "$target" ] || [ "$target" = null ]; then
        printf '\nNo updates available.\n'
        return 0
    fi
    printf '\nTarget version: %s\n' "$target"

    # Pre-snapshot persist for the version we're about to install.
    # Inheritance is always running -> target — NOT current (sysupdate's
    # "highest installed"), because in a rolled-back state `current` may
    # point to a known-bad version we explicitly avoided booting.
    if [ -d "$THEATRE_DATA/@persist/$target" ]; then
        printf '@persist/%s already exists, leaving as-is\n' "$target"
    else
        printf '\n>>> btrfs subvolume snapshot @persist/%s @persist/%s\n' "$running" "$target"
        btrfs subvolume snapshot \
            "$THEATRE_DATA/@persist/$running" \
            "$THEATRE_DATA/@persist/$target"
    fi

    # Install the pinned version. If upstream's SHA256SUMS has moved on
    # (newer version published since our check-new), sysupdate will
    # refuse rather than silently install the newer one — exactly what
    # we want, since we've pre-snapshotted persist for $target only.
    # Re-run `theatre-os update` to pick up the newer version cleanly.
    printf '\n>>> systemd-sysupdate --verify=no update %s\n' "$target"
    /usr/lib/systemd/systemd-sysupdate --verify=no update "$target"

    # GC orphan @persist subvols (any @persist/<x> with no matching @os/<x>).
    # sysupdate did its own InstancesMax GC on @os, so the survivors here
    # are the ones we should keep persist for. This also cleans up the
    # pre-snapshot from step 3 if `update` above failed (in which case we
    # never reach this line — but on the *next* `theatre-os update` run,
    # this loop will sweep the orphan).
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

    printf '\nUpdate complete. Reboot to use %s.\n' "$target"
    case "$reboot_mode" in
        yes) systemctl reboot ;;
        no)  printf 'Skipping reboot (--no-reboot).\n' ;;
        ask) if confirm "Reboot now?" Y; then systemctl reboot; fi ;;
    esac
}
