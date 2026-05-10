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

exec sudo mkosi "$@"
