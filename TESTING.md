# theatre-os — testing

End-to-end validation of the `theatre-os` CLI verbs against a real
booted image in qemu. Catches regressions both in our shell code and
in the underlying btrfs / systemd / kernel behaviour we depend on.

## Run

```sh
./tests/run.sh                  # all cases
./tests/run.sh 02-restore       # one case (omit the .sh suffix)
```

The harness auto-builds the image if `mkosi.output/theatre-os_<v>.raw`
for the current `mkosi.version` doesn't exist, so a clean repo just
works. Re-runs use the existing build (build is the slow part —
~5min — vs ~90s to run all cases against a built image).

Exits 0 on success, 1 on any failed assertion. Prints per-case
OK/FAIL lines as it goes.

## What gets validated

The harness boots one VM and runs each case sequentially against it,
with `cleanup_persist` (deletion of all `*-snap-*`, `*-experiment-*`,
`*-pre-restore-*` subvols) between cases so each starts from a known
state. Cases that need to verify reboot-time behaviour reboot the VM
themselves; the harness re-establishes SSH afterwards.

### `01-snapshot` — snapshot/list/delete/prune

No reboot. Pure btrfs subvol manipulation, all observable from
within one ssh session.

- Take unnamed → name conforms to `<v>-snap-<ts>` pattern.
- Take named → name includes the suffix.
- List shows both.
- Delete by name suffix (unique resolution) removes one.
- Ambiguous id refuses with helpful error.
- Missing id refuses.
- Invalid name (special chars) refuses at input validation.
- Manufacture a 2025-stamped snapshot, run `prune` (date filter
  parses the snap-creation timestamp from the name, not from
  filesystem metadata), verify it's deleted.

### `02-restore` — snapshot → mutate → restore → reboot → verify

Reboots the VM mid-case.

- Write `ORIGINAL` to `/home/kodi/marker.txt`.
- Take a snapshot.
- Overwrite marker with `MUTATED`.
- Run `theatre-os restore <snap>`, decline reboot prompt.
- Verify a `-pre-restore-` subvol exists on disk.
- Reboot via the harness.
- Verify the marker reads `ORIGINAL` again on the restored persist.
- Verify the `-pre-restore-` backup is preserved post-reboot
  (undo-of-undo).

### `03-experiment` — enter → write to /usr → reboot → verify clean

The case the README originally flagged as "needs prototyping in a
VM". Now ensures the answer stays right across kernel/systemd
updates.

- Pre-flight: confirm `/` is RO and `/usr` writes fail (the
  loud-failure barrier we rely on).
- Enter experiment mode (auto-confirm).
- Verify `/` is now RW.
- Verify `/` is mounted on `@os/<v>-experiment-<u>`.
- Write to `/usr/EXPERIMENT_MARKER` (would fail in normal mode).
- Verify motd advertises experiment mode.
- Write a marker to `/home/kodi/` (lands in the throwaway @persist).
- Reboot via the harness.
- Verify `/` is RO again.
- Verify `/` is on a non-experiment `@os/<v>` (the fresh snapshot).
- Verify both markers (in `/usr` and `/home/kodi`) are gone.
- Verify experiment forensic subvols (both `@os` and `@persist`)
  are preserved on disk for browsing.
- Verify `/usr` writes fail again.

### Not yet covered

- **Boot-time persist snapshot + orphan GC** — the initrd's
  `snapshot.sh` (fork `@persist/<v>` from `last-booted-version` on
  first boot of a new version) and `theatre-os-persist-gc.service`
  (reap orphan `@persist/<v>`) only fire across an actual version
  change, so they share the two-builds cost above. Until that's wired,
  validate manually: `journalctl -b -u theatre-os-persist-snapshot`
  (in the initrd journal) and `-u theatre-os-persist-gc`, plus
  `cat /system/data/last-booted-version` and
  `btrfs subvolume list /system/data` after an update + reboot.
- Kodi actually rendering — needs real GPU; not testable in qemu.
- Hardware-specific tweaks (BT/WOL/power-key) — phase 6, on T480
  via AMT KVM.

## Inside

- `tests/lib.sh` — shared helpers: VM lifecycle (`vm_start`,
  `vm_wait`, `vm_ssh`, `vm_reboot`, `vm_kill`), persist cleanup,
  assertion helpers (`assert_eq`, `assert_match`,
  `assert_file_exists_in_vm`, `assert_file_absent_in_vm`).
- `tests/run.sh` — orchestrator: build-if-needed, boot once, run
  cases, summary.
- `tests/cases/*.sh` — one file per test case, sourced into a
  subshell by `run.sh` so failures don't kill the harness.

The vsock CID is pinned at 4242 (`mkosi --vsock-cid 4242`) so the
harness doesn't have to scrape mkosi output to discover it. If you
need to run multiple test VMs concurrently, change the constant.

## When to run

- Before pushing the `phase-*` branches.
- Before calling `./publish.sh` to drop a new release on dufs (so the
  next on-box `updatectl update host` doesn't pull a regressed CLI
  or a broken initrd persist-snapshot step).
- After bumping any package likely to affect the CLI plumbing
  (systemd, btrfs-progs, kernel — i.e. most Arch updates).
- When a `theatre-os experiment` or `theatre-os restore` invocation
  on the real T480 surprises you: re-run locally first to see if it
  surprises the test too.
