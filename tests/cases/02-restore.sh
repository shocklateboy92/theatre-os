# tests/cases/02-restore.sh — validate restore: snapshot → mutate
# persist → restore → reboot → verify mutation undone.
#
# This case reboots the VM as part of its flow.

# ---- Write a marker file to /home/kodi (persist) ----
vm_ssh 'echo "ORIGINAL" > /home/kodi/marker.txt'
out=$(vm_ssh 'cat /home/kodi/marker.txt')
assert_eq "$out" "ORIGINAL" "marker written before snapshot"

# ---- Take a snapshot of the current persist state ----
vm_ssh 'theatre-os snapshot before_mutation' >/dev/null
log "snapshot taken"

# ---- Mutate persist: change the marker ----
vm_ssh 'echo "MUTATED" > /home/kodi/marker.txt'
out=$(vm_ssh 'cat /home/kodi/marker.txt')
assert_eq "$out" "MUTATED" "marker mutated after snapshot"

# ---- Run restore against the snapshot ----
# restore is interactive: confirms then offers reboot. We feed
# y / n: yes to proceed, no to reboot (we'll trigger the reboot
# ourselves so vm_reboot can wait for SSH cleanly).
# shellcheck disable=SC2086
ssh -tt $SSH_OPTS "$VM_HOST" 'theatre-os restore before_mutation' <<'EOF' 2>/dev/null
y
n
EOF
log "restore staged"

# Verify the staging happened: a -pre-restore- subvol now exists.
out=$(vm_ssh 'btrfs subvolume list /system/data')
assert_match "$out" '-pre-restore-' "pre-restore backup subvol exists"

# ---- Reboot to apply ----
vm_reboot

# ---- Marker should be ORIGINAL again on the restored persist ----
out=$(vm_ssh 'cat /home/kodi/marker.txt')
assert_eq "$out" "ORIGINAL" "marker is original after restore + reboot"

# ---- Pre-restore backup is still on disk for undo-of-undo ----
out=$(vm_ssh 'btrfs subvolume list /system/data')
assert_match "$out" '-pre-restore-' "pre-restore backup preserved post-reboot"
