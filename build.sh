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
