# theatre-os shared shell helpers. Sourced by /usr/bin/theatre-os and
# /usr/lib/theatre-os/cmd-*.sh. Pure POSIX shell (no bashisms) so the CLI
# stays runnable under any /bin/sh; the bin script just sources us.
#
# Conventions:
#   - die "msg"          -> log + exit 1
#   - confirm "prompt"   -> y/N read, returns 0 on yes
#   - All functions assume `set -eu` is in effect at the call site.

# Where the data partition lives in the running rootfs (set up by the
# initrd, see README → Boot sequence). All btrfs operations target this.
THEATRE_DATA=/system/data

die() {
    printf 'theatre-os: %s\n' "$*" >&2
    exit 1
}

# Ask the user for y/N; default N. Returns 0 on yes, 1 on no.
# Refuses to prompt if stdin isn't a tty (no silent default-yes).
confirm() {
    if [ ! -t 0 ]; then
        die "refusing to prompt for confirmation: stdin is not a tty"
    fi
    printf '%s [y/N] ' "$1" >&2
    read -r reply || return 1
    case "$reply" in
        y|Y|yes|YES) return 0 ;;
        *)           return 1 ;;
    esac
}

# Read the version of the running OS image. mkosi stamps this into
# /usr/lib/os-release as IMAGE_VERSION (NOT VERSION_ID — that's the
# distro version field; VERSION_ID is unset for rolling Arch). This is
# the same value the initrd's sysroot.mount was templated against, i.e.
# the @os/<v> and @persist/<v> currently mounted.
running_version() {
    # shellcheck disable=SC1091
    . /usr/lib/os-release
    [ -n "${IMAGE_VERSION:-}" ] || die "IMAGE_VERSION missing from /usr/lib/os-release"
    printf '%s' "$IMAGE_VERSION"
}

# Are we booted off an experiment-mode subvolume? In experiment mode the
# initrd mounted @os/<v>-experiment-<u> at / (via the live rename trick;
# see README → Experiment mode). Detect by inspecting the source of /.
is_experiment_mode() {
    src=$(findmnt -no SOURCE /) || die "findmnt / failed"
    case "$src" in
        *@os/*-experiment-*) return 0 ;;
        *)                   return 1 ;;
    esac
}

# List subvol *names* (not paths) under one of @os or @persist on the data
# partition. One per line, lexicographically sorted (matches sysupdate's
# @v ordering).
list_versions() {
    container=$1   # @os or @persist
    btrfs subvolume list -o "$THEATRE_DATA/$container" 2>/dev/null \
        | awk '{print $NF}' \
        | sed -n "s|^$container/||p" \
        | sort -u
}
