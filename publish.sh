#!/bin/sh
# publish.sh — upload sysupdate artefacts (.tar + .efi) to the homelab dufs
# instance. The .raw stays local (it's an install-only artefact, not used
# by sysupdate; see README → Initial install / disk provisioning).
#
# dufs's push endpoint is open for PUT inside the LAN trust boundary; no
# auth needed (see README → Architecture → Distribution).
#
# Usage: ./publish.sh [profile]   (profile: t480 (default) | zbook)
# The profile selects BOTH the local output subdir to read from and the
# dufs device path to push to; the latter MUST match the Path= baked into
# that profile's sysupdate .transfer files, or the box won't find its
# updates.
#
# Order matters: artefacts first, then SHA256SUMS last, so consumers (i.e.
# `updatectl` on the box) never see a checksum file referencing a
# not-yet-uploaded payload. PUT is idempotent: re-running for the same build
# is a no-op (replaces with identical bytes).

set -eu

PROFILE="${1:-t480}"
case "$PROFILE" in
    t480)  DEVICE=theatre-t480 ;;
    zbook) DEVICE=bedroom-tv ;;
    *) echo "publish.sh: unknown profile '$PROFILE' (expected t480|zbook)" >&2; exit 2 ;;
esac

PUSH="https://push.apps.lasath.com/$DEVICE"
PULL="https://static.apps.lasath.com/sysupdate/$DEVICE"
# Single shared output dir (see build.sh's note on why output is NOT
# split per profile). Build+publish one target at a time: this reads
# the most recent SHA256SUMS, which belongs to whatever you built last.
OUTDIR="$(dirname "$0")/mkosi.output"

# Discover the version from the local SHA256SUMS file. mkosi just wrote
# it, it covers exactly the artefacts from this build, no need to re-ask
# mkosi.version.
LOCAL_SUMS=$(ls "$OUTDIR"/theatre-os_*.SHA256SUMS 2>/dev/null | tail -n1)
[ -n "$LOCAL_SUMS" ] || { echo "publish.sh: no SHA256SUMS in $OUTDIR" >&2; exit 1; }

# Ensure the device subdir exists. dufs's docs claim PUT auto-creates
# parent dirs, but in practice it doesn't — PUT to a nonexistent
# directory returns 404. WebDAV MKCOL works and is idempotent enough
# for our purposes: 201 on create, 405 if it already exists, both fine.
curl -fsS -X MKCOL "$PUSH/" -o /dev/null \
    -w "MKCOL %{http_code}\n" || true

# Upload only the sysupdate artefacts (.tar and .efi). Skip .raw —
# install-only, kept local.
#
# sha256sum's "binary mode" output prefixes filenames with `*`; strip it
# (sub() not gsub() — it only appears at the start of field 2).
awk '{sub(/^\*/, "", $2); print $2}' "$LOCAL_SUMS" | while read -r f; do
    case "$f" in
        *.tar|*.efi)
            echo ">>> PUT $f"
            # PUT to the full file URL, not the directory. dufs returns
            # 404 for the directory-with-trailing-slash form even though
            # curl supports it for other WebDAV servers.
            curl -fT "$OUTDIR/$f" "$PUSH/$f"
            ;;
        *)
            echo "    skip $f (not a sysupdate artefact)"
            ;;
    esac
done

# Merge local SHA256SUMS into whatever's already on dufs, then upload.
# Filter out .raw lines from the local sums so the published index matches
# what's actually fetchable from dufs.
TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT
{
    curl -fsS "$PULL/SHA256SUMS" 2>/dev/null || true
    grep -E '\.(tar|efi)$' "$LOCAL_SUMS"
} | sort -u > "$TMP"

echo ">>> PUT SHA256SUMS"
curl -fT "$TMP" "$PUSH/SHA256SUMS"

echo "Published"
