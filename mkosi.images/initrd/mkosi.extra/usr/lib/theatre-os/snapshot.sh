#!/bin/sh
# Ensure /system/data/@persist/<IMAGE_VERSION> exists before
# sysroot-system-persist.mount attaches it.
#
# Runs in the initrd, invoked by theatre-os-persist-snapshot.service.
# /sysroot/system/data is already mounted (subvolid=5 of the
# theatre-os-data partition) by sysroot-system-data.mount; we operate
# via that view.
#
# IMAGE_VERSION is read from THIS initrd's /usr/lib/os-release.
# mkosi.images/initrd/mkosi.postinst stamps it in at build time
# (inherits from the top-level mkosi.version), so the value always
# matches the @os/<v> this UKI is paired with — the same value
# mkosi.finalize substitutes into the .mount units' subvol= paths.
#
# Why the snapshot happens in the initrd, at boot:
#
#   By the time this runs, the previous boot has cleanly shut down, so
#   forking @persist for a new version always captures a settled
#   on-disk state — not "midway through running services that will
#   write more before reboot", which would leave the new version
#   coming up believing it had an unclean shutdown.
#
# Logic:
#
#   case 1: @persist/<IMAGE_VERSION> already exists
#     → no-op. Most boots fall here: we booted v1 yesterday and are
#       booting v1 again today; the snapshot was taken at the first
#       boot of v1. Also the path the freshly-`dd`-installed box takes
#       on its very first boot, because repart already created (and
#       seeded) @persist/<install-version> at install time — see
#       mkosi.repart.in/10-data.conf.in.
#
#   case 2: @persist/<IMAGE_VERSION> doesn't exist, but
#           @persist/<last-booted> does
#     → snapshot @persist/<last-booted> → @persist/<IMAGE_VERSION>.
#       The "first boot of a new version" path. sysupdate dropped the
#       new UKI on the ESP and extracted @os/<IMAGE_VERSION>; now we're
#       booting it for the first time. Fork the new @persist from the
#       previous boot's final, settled @persist. The seeded /var,
#       /home/kodi, /var/lib/theatre-os skeleton that the bind mounts
#       (sysroot-var.mount, sysroot-home-kodi.mount, the machine-id
#       bind) depend on rides along in the snapshot for free.
#
#   case 3: neither @persist/<IMAGE_VERSION> nor a usable
#           last-booted-version marker exists
#     → create an EMPTY @persist/<IMAGE_VERSION>. On a normally
#       provisioned theatre-os this should not happen: the install
#       version is seeded by repart (case 1) and every version
#       thereafter forks from last-booted (case 2). It's a
#       last-resort fallback for a wiped/orphaned @persist. NOTE: an
#       empty subvol has none of the bind-mount target directories,
#       so the per-version bind mounts may fail and drop the box to
#       emergency — recover by re-`dd`'ing the install media (which
#       seeds @persist properly). We don't recreate the seed skeleton
#       here; that logic lives in repart and is install-time only.
#
# After any of the above, write last-booted-version=<IMAGE_VERSION>.
# One write per boot, so a hard crash before the next clean shutdown
# is harmless: the next boot still snapshots from the settled @persist
# left by the last clean shutdown before the crash.

set -eu

log() { printf 'theatre-os-persist: %s\n' "$*"; }
die() { printf 'theatre-os-persist: FATAL: %s\n' "$*" >&2; exit 1; }

# Read IMAGE_VERSION from THIS initrd's /usr/lib/os-release. mkosi
# stamps it at build time (mkosi.postinst); mkosi.finalize substitutes
# @VERSION@ in the .mount units to the same value so everything stays
# in sync.
# shellcheck disable=SC1091
. /usr/lib/os-release
IMAGE_VERSION=${IMAGE_VERSION:-}
[ -n "$IMAGE_VERSION" ] || die "IMAGE_VERSION missing from /usr/lib/os-release"

DATA=/sysroot/system/data
PERSIST="$DATA/@persist"
LAST_BOOTED_FILE="$DATA/last-booted-version"

[ -d "$DATA" ] || die "$DATA not present (is sysroot-system-data.mount up?)"

# Ensure the @persist container directory exists. On a normal box
# repart created it at install time, but guard anyway (a wiped data
# partition, or a partition formatted without the install seed). It's
# a plain directory at the btrfs root, not a subvolume — the per-
# version @persist/<v> entries below are the subvolumes.
if [ ! -d "$PERSIST" ]; then
    log "creating @persist container directory"
    mkdir "$PERSIST"
fi

target="$PERSIST/$IMAGE_VERSION"

if [ -d "$target" ]; then
    log "@persist/$IMAGE_VERSION already exists (no-op)"
else
    # Need to create it. Snapshot from last-booted if we have one;
    # otherwise this is the first-ever boot of this version with no
    # prior persist to fork from, so start empty.
    last_booted=""
    if [ -f "$LAST_BOOTED_FILE" ]; then
        last_booted=$(cat "$LAST_BOOTED_FILE")
    fi

    if [ -n "$last_booted" ] && [ -d "$PERSIST/$last_booted" ]; then
        log "snapshotting @persist/$last_booted → @persist/$IMAGE_VERSION"
        btrfs subvolume snapshot \
            "$PERSIST/$last_booted" \
            "$target" >/dev/null
    else
        log "creating empty @persist/$IMAGE_VERSION (no prior version)"
        btrfs subvolume create "$target" >/dev/null
    fi
fi

# Record what we booted. Written AFTER the snapshot succeeds so a
# failure leaves last-booted-version pointing at the previous
# (known-good) version — meaning the next boot snapshots from the
# same place it would have if this boot hadn't happened.
printf '%s\n' "$IMAGE_VERSION" > "$LAST_BOOTED_FILE"
log "wrote last-booted-version=$IMAGE_VERSION"
