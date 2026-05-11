# tests/lib.sh — shared helpers for the theatre-os VM-driven test
# harness. Sourced by run.sh and individual cases under cases/.
#
# Conventions:
#   - All helpers assume `set -eu` is in effect.
#   - VM_CID is set by run.sh before any case runs (we pin it via
#     `mkosi --vsock-cid` so the harness doesn't have to scrape mkosi
#     output to discover it).
#   - vm_ssh runs commands as root over vsock SSH using the same key
#     mkosi.extra/root/.ssh/authorized_keys was built against (the
#     dev box's user key).
#   - assert_* helpers print "OK" / "FAIL" and a reason on stderr;
#     FAIL exits the case with status 1 (so run.sh can count failures).

# Pinned vsock CID for the test VM. Arbitrary high number, unlikely
# to collide with anything else on the host.
VM_CID=4242
VM_HOST="root@vsock%${VM_CID}"

# Where in the running VM the data partition lives (must match
# THEATRE_DATA in /usr/lib/theatre-os/lib.sh).
VM_DATA=/system/data

# How long to wait for VM SSH to come up after boot or reboot.
VM_BOOT_TIMEOUT=60

# Common SSH options. -o BatchMode=yes prevents the harness from
# hanging waiting for password prompts if key auth fails.
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o ConnectTimeout=5 -o LogLevel=ERROR"

# --- VM lifecycle ---------------------------------------------------

# Start the VM in the background. Captures the qemu PID via mkosi's
# own process tree. The .raw artefact is selected by --image-version,
# which run.sh determines from mkosi.version output.
vm_start() {
    version=$1
    log "starting VM (image-version=$version, cid=$VM_CID)"
    # Background mkosi vm; redirect its stdout/stderr to a logfile so
    # we don't pollute test output but can grep it on failure.
    sudo mkosi --image-version "$version" --vsock-cid "$VM_CID" vm \
        > "$VM_LOG" 2>&1 &
    VM_PID=$!
    log "VM started, pid=$VM_PID, log=$VM_LOG"
}

# Block until SSH is reachable. Exits the case with failure if the
# VM doesn't come up in VM_BOOT_TIMEOUT seconds.
vm_wait() {
    log "waiting for VM SSH (cid=$VM_CID, timeout=${VM_BOOT_TIMEOUT}s)"
    deadline=$(($(date +%s) + VM_BOOT_TIMEOUT))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        # shellcheck disable=SC2086
        if ssh $SSH_OPTS "$VM_HOST" true 2>/dev/null; then
            log "VM SSH is up"
            return 0
        fi
        sleep 1
    done
    fail "VM did not come up within ${VM_BOOT_TIMEOUT}s; tail of vm log:"
    tail -20 "$VM_LOG" >&2
    exit 1
}

# Run a command (or shell snippet) inside the VM as root. Stdout is
# returned to the caller. Exit code is propagated.
vm_ssh() {
    # shellcheck disable=SC2086
    ssh $SSH_OPTS "$VM_HOST" "$@"
}

# Reboot the VM and wait for it to come back. We allow `systemctl
# reboot` to race with us — SSH will drop, we sleep briefly to let
# the kernel actually start the reboot, then poll for SSH again.
vm_reboot() {
    log "rebooting VM"
    # `|| true`: SSH connection will be killed mid-reboot, that's expected.
    vm_ssh "systemctl reboot" 2>/dev/null || true
    sleep 3   # let the reboot actually start before we poll
    vm_wait
}

# Kill the VM and wait for the qemu process to exit. Idempotent.
vm_kill() {
    [ -n "${VM_PID:-}" ] || return 0
    log "killing VM (pid=$VM_PID)"
    sudo kill -- -"$VM_PID" 2>/dev/null || true
    sudo kill "$VM_PID" 2>/dev/null || true
    # Wait briefly; if it's still alive, SIGKILL.
    for _ in 1 2 3 4 5; do
        if ! kill -0 "$VM_PID" 2>/dev/null; then break; fi
        sleep 1
    done
    sudo kill -9 "$VM_PID" 2>/dev/null || true
    wait "$VM_PID" 2>/dev/null || true
    VM_PID=
}

# --- Cleanup helpers (between cases) --------------------------------

# Delete all transient persist subvols (snapshots, experiment subvols,
# pre-restore backups) so the next case starts from a clean state.
# Leaves @os/<v> and @persist/<v> alone — those are the live ones.
cleanup_persist() {
    log "cleanup: deleting transient subvols"
    vm_ssh '
        for sub in $(btrfs subvolume list /system/data \
            | awk "{print \$NF}" \
            | grep -E "(-snap-|-experiment-|-pre-restore-)" || true); do
            btrfs subvolume delete "/system/data/$sub" || true
        done
    '
}

# --- Assertions ----------------------------------------------------

# assert_eq <actual> <expected> <description>
assert_eq() {
    actual=$1; expected=$2; desc=$3
    if [ "$actual" = "$expected" ]; then
        ok "$desc (got: $actual)"
    else
        fail "$desc: expected '$expected', got '$actual'"
    fi
}

# assert_match <string> <regex> <description>
assert_match() {
    string=$1; pattern=$2; desc=$3
    if printf '%s' "$string" | grep -qE -- "$pattern"; then
        ok "$desc"
    else
        fail "$desc: '$string' did not match /$pattern/"
    fi
}

# assert_file_exists_in_vm <path> <description>
assert_file_exists_in_vm() {
    path=$1; desc=$2
    if vm_ssh "test -e $path"; then
        ok "$desc ($path exists)"
    else
        fail "$desc: $path does not exist in VM"
    fi
}

# assert_file_absent_in_vm <path> <description>
assert_file_absent_in_vm() {
    path=$1; desc=$2
    if vm_ssh "test ! -e $path"; then
        ok "$desc ($path absent)"
    else
        fail "$desc: $path UNEXPECTEDLY exists in VM"
    fi
}

# --- Output helpers ------------------------------------------------

log() {
    printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" >&2
}

ok() {
    printf '  \033[32mOK\033[0m   %s\n' "$*" >&2
}

fail() {
    printf '  \033[31mFAIL\033[0m %s\n' "$*" >&2
    CASE_FAILED=1
}
