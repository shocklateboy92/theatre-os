#!/bin/sh
# Build entry point. Renders version-stamped templates that mkosi /
# systemd-repart can't expand on their own (Subvolumes= doesn't accept
# specifiers — see README.md "Build & publish"), then invokes mkosi.
#
# Any args are passed through to mkosi:
#   ./build.sh             →  sudo mkosi build
#   ./build.sh -f build    →  sudo mkosi -f build
#   ./build.sh vm          →  sudo mkosi vm
#   etc.
#
# Lives at repo root (NOT under scripts/) so it's hard to invoke
# `mkosi` directly by accident — running mkosi without the templating
# step uses stale repart configs from the last build.

set -eu

cd "$(dirname "$0")"

VERSION="$(./mkosi.version)"

# Prune old artefacts in mkosi.output/ — each build produces ~11 GiB
# of output (.raw + .tar + .efi + .SHA256SUMS) and they accumulate.
# Keep the most recent N-1 strictly-older builds so the previous
# known-working .raw is still on disk if this build fails or we want
# to compare. The build we're about to do replaces the Nth slot.
#
# Date-based version stamps sort lexicographically as time order, so
# `sort` puts oldest first; `head -n -K` drops the K newest.
LOCAL_RETAIN=2
existing=$(ls mkosi.output/theatre-os_*.SHA256SUMS 2>/dev/null \
    | sed 's|.*/theatre-os_\(.*\)\.SHA256SUMS|\1|' \
    | grep -v "^$VERSION$" \
    | sort -u)
# Keep the (LOCAL_RETAIN - 1) NEWEST of the strictly-older builds;
# drop everything else. (We're about to write the new build, which
# fills the Nth retention slot.)
to_drop=$(printf '%s\n' "$existing" | head -n "-$((LOCAL_RETAIN - 1))" || true)
for v in $to_drop; do
    [ -n "$v" ] || continue
    echo "build.sh: pruning local mkosi.output/theatre-os_$v.*"
    sudo rm -f mkosi.output/theatre-os_"$v".raw \
                mkosi.output/theatre-os_"$v".tar \
                mkosi.output/theatre-os_"$v".efi \
                mkosi.output/theatre-os_"$v".SHA256SUMS \
                mkosi.output/theatre-os_"$v"
done

# Discover the git SHA so it can flow through to the running OS's
# /usr/lib/os-release as THEATREOS_GIT_SHA. Lets us trace any
# running version back to the source. -dirty suffix if the worktree
# has uncommitted changes (so we don't claim a dev build is the same
# as the committed SHA it nominally derives from). If the build is
# happening outside a git checkout (e.g. CI from a tarball), fall
# back to "unknown" rather than failing the build.
if git rev-parse --verify HEAD >/dev/null 2>&1; then
    sha=$(git rev-parse --short=12 HEAD)
    if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
        sha="${sha}-dirty"
    fi
    THEATREOS_GIT_SHA=$sha
else
    THEATREOS_GIT_SHA=unknown
fi
export THEATREOS_GIT_SHA

# Render *.in templates from mkosi.repart.in/ into mkosi.repart/,
# substituting @VERSION@. Static .conf files in the same template dir
# are copied verbatim. Output dir is gitignored.
tmpl_dir=mkosi.repart.in
out_dir=mkosi.repart

mkdir -p "$out_dir"
# Wipe to avoid stale outputs from previous builds (e.g. if a template
# was renamed or removed since last build). Use find instead of glob
# expansion to handle empty dirs cleanly.
find "$out_dir" -maxdepth 1 -name '*.conf' -type f -delete

for src in "$tmpl_dir"/*; do
        [ -f "$src" ] || continue
        base="$(basename "$src")"
        case "$base" in
                *.conf.in)
                        out="$out_dir/${base%.in}"
                        sed "s|@VERSION@|$VERSION|g" "$src" > "$out"
                        ;;
                *.conf)
                        cp "$src" "$out_dir/$base"
                        ;;
        esac
done

# Fetch HAKA (custom fork of script.program.homeassistant) into the
# rootfs tree. Pinned to a commit SHA so a build is reproducible to
# the exact bytes we shipped. Bump HAKA_SHA when promoting a new
# upstream commit.
#
# The destination is gitignored — the source of truth is the URL +
# SHA below, not a snapshot in the repo. The .git dir is dropped
# after checkout (it's not needed at runtime and bloats the image);
# a .haka-sha stamp file is left behind so we can skip re-cloning
# when the SHA hasn't changed.
HAKA_REPO=https://github.com/shocklateboy92/HAKA.git
HAKA_SHA=a26733d77f7645295fbf48b0de460947904929cc  # work/fernando/mdi-icons tip
HAKA_DEST=mkosi.extra/usr/share/kodi/addons/script.program.homeassistant

if [ "$(cat "$HAKA_DEST/.haka-sha" 2>/dev/null)" != "$HAKA_SHA" ]; then
    echo "build.sh: fetching HAKA at $HAKA_SHA"
    rm -rf "$HAKA_DEST"
    mkdir -p "$(dirname "$HAKA_DEST")"
    git clone --quiet "$HAKA_REPO" "$HAKA_DEST"
    git -C "$HAKA_DEST" checkout --quiet "$HAKA_SHA"
    rm -rf "$HAKA_DEST/.git"
    echo "$HAKA_SHA" > "$HAKA_DEST/.haka-sha"
fi

# Default to `build` if no verb supplied; mkosi requires explicit verbs
# in some configs.

# Default to `build` if no verb supplied; mkosi requires explicit verbs
# in some configs.
if [ "$#" -eq 0 ]; then
        set -- build
fi

# --preserve-env=THEATREOS_GIT_SHA: sudo strips environment variables
# by default. mkosi.conf has Environment=THEATREOS_GIT_SHA which says
# "pass through whatever the host has", but only if the host's value
# survives sudo first. The narrow allowlist (one var) is safer than -E.
exec sudo --preserve-env=THEATREOS_GIT_SHA mkosi "$@"
