# tests/cases/01-snapshot.sh — validate the snapshot family of verbs.
#
# Order: take unnamed → take named → list (verifies both appear) →
# delete by name suffix (verifies unique resolution) → delete by full
# name → list (verifies clean) → take 31-day-old fake → prune
# (verifies date filtering).
#
# Doesn't reboot. Pure btrfs subvol manipulation, all observable
# from a single ssh session.

# ---- Take unnamed ----
out=$(vm_ssh 'theatre-os snapshot 2>&1')
assert_match "$out" 'Took snapshot @persist/.*-snap-' "take unnamed prints success"

# ---- Take named ----
out=$(vm_ssh 'theatre-os snapshot test_named 2>&1')
assert_match "$out" 'Took snapshot @persist/.*-snap-.*-test_named' "take named includes name in subvol"

# ---- List shows both ----
out=$(vm_ssh 'theatre-os snapshot list')
count=$(printf '%s\n' "$out" | grep -c '\-snap\-' || true)
assert_eq "$count" 2 "list shows 2 snapshots"

# ---- Resolve by suffix and delete ----
vm_ssh 'theatre-os snapshot delete test_named'
out=$(vm_ssh 'theatre-os snapshot list')
count=$(printf '%s\n' "$out" | grep -c '\-snap\-' || true)
assert_eq "$count" 1 "delete by name suffix removes 1"

# ---- Ambiguous resolution (multiple matches) refuses ----
vm_ssh 'theatre-os snapshot ambig_a' >/dev/null
vm_ssh 'theatre-os snapshot ambig_b' >/dev/null
out=$(vm_ssh 'theatre-os snapshot delete ambig 2>&1' || true)
assert_match "$out" 'ambiguous' "ambiguous id refuses with helpful error"

# ---- No matches refuses ----
out=$(vm_ssh 'theatre-os snapshot delete nonexistent 2>&1' || true)
assert_match "$out" 'no snapshot matching' "missing id refuses"

# ---- Invalid name (special chars) refuses ----
out=$(vm_ssh 'theatre-os snapshot "bad name with spaces" 2>&1' || true)
assert_match "$out" 'name must match' "invalid name refuses"

# ---- Manufacture an old snapshot, prune ----
# Forge a snapshot named with a 2025 timestamp so prune's 30-day
# cutoff catches it. We can't actually backdate a btrfs subvol's
# creation time, but our prune logic parses the timestamp from the
# subvol NAME, not from any filesystem metadata, so the forge is
# convincing for our purposes.
running=$(vm_ssh '. /usr/lib/os-release; echo $IMAGE_VERSION')
old_name="${running}-snap-2025-01-01-0000-old"
vm_ssh "btrfs subvolume snapshot /system/data/@persist/$running /system/data/@persist/$old_name"

# prune is interactive (confirms before deleting), so we have to feed
# it 'yes' on stdin via SSH. Use a here-doc redirected via SSH stdin
# AND request a tty (-t -t) so confirm()'s `[ -t 0 ]` check passes.
# shellcheck disable=SC2086
ssh -tt $SSH_OPTS "$VM_HOST" 'theatre-os snapshot prune' <<'EOF' 2>/dev/null
y
EOF

# Verify the old snap is gone.
out=$(vm_ssh 'theatre-os snapshot list')
if printf '%s' "$out" | grep -q '2025-01-01'; then
    fail "prune did not delete the 2025 snapshot"
else
    ok "prune deleted the >30-day-old snapshot"
fi
