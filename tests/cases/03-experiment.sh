# tests/cases/03-experiment.sh — validate experiment mode: enter →
# write to /usr (normally fails, should succeed in experiment) →
# reboot → verify back to RO + write gone + forensic subvols
# preserved.
#
# This is the verb the README flagged as "needs prototyping in a
# VM" — that flag is now answered, but this test ensures it stays
# answered across kernel/systemd updates.

# ---- Pre-flight: / should be RO ----
out=$(vm_ssh 'findmnt -no OPTIONS /')
assert_match "$out" '^ro' "/ is RO before experiment"

# ---- Pre-flight: /usr writes fail ----
if vm_ssh 'touch /usr/PRE_EXPERIMENT_TEST 2>/dev/null'; then
    fail "/usr writes UNEXPECTEDLY succeeded before experiment mode"
    vm_ssh 'rm -f /usr/PRE_EXPERIMENT_TEST'
else
    ok "/usr writes correctly fail before experiment"
fi

# ---- Enter experiment mode ----
# Interactive confirm; feed 'y'.
# shellcheck disable=SC2086
ssh -tt $SSH_OPTS "$VM_HOST" 'theatre-os experiment' <<'EOF' 2>/dev/null
y
EOF
log "experiment mode entered"

# ---- / should be RW now ----
out=$(vm_ssh 'findmnt -no OPTIONS /')
assert_match "$out" '^rw' "/ is RW after entering experiment mode"

# ---- We're on a -experiment- subvol ----
out=$(vm_ssh 'findmnt -no SOURCE /')
assert_match "$out" '@os/.*-experiment-' "/ is mounted on @os/<v>-experiment-<u>"

# ---- /usr writes succeed ----
vm_ssh 'echo "EXPERIMENT_DATA" > /usr/EXPERIMENT_MARKER'
out=$(vm_ssh 'cat /usr/EXPERIMENT_MARKER')
assert_eq "$out" "EXPERIMENT_DATA" "/usr write succeeded in experiment mode"

# ---- Persist writes also succeed (and would normally too, but
# they're now landing in the throwaway -experiment- @persist subvol) ----
vm_ssh 'echo "PERSIST_EXP" > /home/kodi/EXPERIMENT_PERSIST_MARKER'

# ---- Motd was written ----
out=$(vm_ssh 'cat /etc/motd 2>&1')
assert_match "$out" 'EXPERIMENT MODE' "motd advertises experiment mode"

# ---- Reboot to leave ----
vm_reboot

# ---- Back to RO ----
out=$(vm_ssh 'findmnt -no OPTIONS /')
assert_match "$out" '^ro' "/ is RO after reboot-to-leave"

# ---- Back on the non-experiment subvol ----
out=$(vm_ssh 'findmnt -no SOURCE /')
if printf '%s' "$out" | grep -q 'experiment'; then
    fail "/ is STILL on an experiment subvol post-reboot ($out)"
else
    ok "/ is on a clean @os/<v> post-reboot"
fi

# ---- Experiment markers are gone ----
assert_file_absent_in_vm /usr/EXPERIMENT_MARKER "experiment /usr write vanished on reboot"
assert_file_absent_in_vm /home/kodi/EXPERIMENT_PERSIST_MARKER "experiment persist write vanished on reboot"

# ---- Forensic subvols still on disk ----
out=$(vm_ssh 'btrfs subvolume list /system/data')
os_exp=$(printf '%s' "$out" | grep -c '@os/.*-experiment-' || true)
persist_exp=$(printf '%s' "$out" | grep -c '@persist/.*-experiment-' || true)
[ "$os_exp" -ge 1 ] && ok "@os experiment subvol preserved" || fail "@os experiment subvol missing"
[ "$persist_exp" -ge 1 ] && ok "@persist experiment subvol preserved" || fail "@persist experiment subvol missing"

# ---- /usr writes fail again ----
if vm_ssh 'touch /usr/POST_EXPERIMENT_TEST 2>/dev/null'; then
    fail "/usr writes UNEXPECTEDLY succeed after reboot"
    vm_ssh 'rm -f /usr/POST_EXPERIMENT_TEST' || true
else
    ok "/usr writes correctly fail after reboot-to-leave"
fi
