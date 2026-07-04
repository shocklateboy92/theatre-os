# theatre-os

Declarative, image-based OS for the home theatre HTPC. Replaces
LibreELEC with a reproducible Arch-derived build. Kodi is the shell;
moonlight-qt launches from within Kodi for game streaming.

This README covers architecture, design choices, and the day-to-day
iteration loop. Operational specifics live elsewhere:

- `AGENTS.md` — target hosts, AMT power control, secrets locations.
- `t480-hardware-quirks.md` — Lenovo T480 specifics (AMT
  provisioning, eDP-1 disable, HDMI 1.4 cap).
- `zbook-hardware-quirks.md` — HP ZBook (bedroom TV) specifics and the
  hardware still to be characterised.
- `legacy-zbook-libreelec.md` — behaviour spec for the retired ZBook,
  kept as a reference for features that may need reimplementing
  (WOL via dock, BT wake, BLE reconnect watchdog, wake chime).
- `TESTING.md` — VM-based test harness for the `theatre-os` CLI.
- `ha-config` (separate repo) — Home Assistant config, Kodi userdata
  deployment, secrets. Anything per-user / stateful / secret lives
  there, not here.

## Architecture

- **Build**: [`mkosi`](https://mkosi.systemd.io/) produces an
  Arch-based rootfs from declarative config in this repo. One build
  emits `theatre-os_<v>.raw` (bootable install media) +
  `theatre-os_<v>.tar` (rootfs for updates) + `theatre-os_<v>.efi`
  (matching UKI) + `SHA256SUMS`.
- **Distribute**: `publish.sh` PUTs `.tar`, `.efi`, `SHA256SUMS` over
  WebDAV to a homelab dufs instance, served back read-only over
  HTTPS. LAN-only DNS, real Let's Encrypt cert. No GPG signing —
  HTTPS + SHA256 covers the realistic threat in a single-tenant
  trust boundary.
- **Deploy**: [`systemd-sysupdate`](https://www.freedesktop.org/software/systemd/man/latest/systemd-sysupdate.html),
  driven via `updatectl` — no wrapper. Each version is a fresh RO
  `@os/<v>` subvol + matching UKI; systemd-boot enumerates UKIs, so
  rollback is picking an older menu entry. The per-version
  `@persist/<v>` is forked at the *next boot* by the initrd, not at
  update time (see Boot sequence).
- **Runtime**: `@os/<v>` btrfs subvolume mounted RO at `/`, no
  overlayfs. Writes to `/usr` and most of `/etc` fail loudly. `/var`,
  `/home/kodi`, and a few identity files bind-mount from a
  per-version `@persist/<v>` subvolume. ESP is mounted RW at `/efi`
  so `bootctl` / sysupdate can write to it.

Reference implementations we lean on:

- [systemd/particleos](https://github.com/systemd/particleos) — mkosi
  + sysupdate + UKI patterns.
- KDE Linux — same UKI + systemd-boot + sysupdate pattern on Arch.
  Different on-disk model (erofs on a shared subvol + shared persist
  for delta downloads via desync); we don't need deltas, so we use
  per-version subvols + per-version persist for stronger isolation
  and simpler plumbing.

## Profiles (per-machine targets)

One repo builds two boxes via [mkosi
profiles](https://mkosi.systemd.io/) (`mkosi.profiles/<profile>/`):

| profile | box | hostname | update path | AVR volume |
|---------|-----|----------|-------------|------------|
| `t480` (default) | Lenovo T480, main theatre | `theatre-t480` | `sysupdate/theatre-t480/` | HA → Denon addon |
| `zbook` | HP ZBook, bedroom TV | `bedroom-tv` | `sysupdate/bedroom-tv/` | HDMI-CEC (Pulse-Eight) |

Everything common lives in `mkosi.conf` + `mkosi.extra/`. Only the
genuinely per-box bits are split into `mkosi.profiles/<profile>/`
(its own `mkosi.conf` overrides + a `mkosi.extra/` overlay):

- **Hostname** — baked, so per profile. The base `mkosi.conf` keeps a
  `theatre-os` fallback only for a stray profile-less build.
- **Update source path** — the shared `usr/lib/sysupdate.d/*.transfer`
  pull from `.../sysupdate/%H/`, where systemd-sysupdate expands `%H` to
  the box's hostname — so each box only pulls its own updates, and the
  path automatically matches the dufs subdir `publish.sh` pushes to. No
  per-profile transfer files needed.
- **Output directory** — all profiles share one `mkosi.output/`.
  Output is deliberately *not* split per profile: the top-level
  `Initrds=%O/initrd` expands `%O` against the default output dir when
  `mkosi.conf` is parsed, *before* any profile override, so a
  per-profile `OutputDirectory=` makes the UKI embed a stale initrd
  from `mkosi.output/` and the image fails to mount its rootfs at boot.
  Build one target at a time and publish it before building the other
  (each build overwrites the shared, unversioned `mkosi.output/initrd`,
  and `publish.sh` reads the most recent `SHA256SUMS`).
- **AVR volume** — the `t480` profile carries the HA→Denon Kodi addon +
  keymap and the AVR event logger; the `zbook` profile ships none of
  them and drives volume over HDMI-CEC instead (`kodi` already depends
  on `libcec`, so the Pulse-Eight USB-CEC adapter works with no extra
  packages).
- **Hardware quirks** — the base cmdline blanks the internal laptop
  panel with `video=eDP-1:d` (Kodi is gbm-direct/single-CRTC, so a live
  internal panel means nothing reaches the TV) — both boxes need it. The
  T480's 40–60% battery charge-threshold udev rule is `t480`-only; the
  ZBook's battery/ALSA/initrd equivalents are TBD (see
  `zbook-hardware-quirks.md`).

Profiles are selected with `--profile`, which `build.sh` passes
through; a bare `./build.sh` defaults to `t480` and behaves exactly as
it did before profiles existed. See "Build & publish".

## Iteration loop

1. SSH into the box. `/` is RO; `pacman -S` and `/etc` edits fail.
2. `theatre-os experiment` to enter experiment mode live (no reboot).
   `pacman -S` and `/etc` edits now work and land in throwaway
   subvols.
3. Reboot → all experimental writes vanish.
4. Promote working changes into the mkosi config in this repo.
5. `./build.sh` → `./publish.sh` → `updatectl update host` on the
   box, reboot.
6. Verify; if broken, reboot and pick the previous UKI from the
   systemd-boot menu. AMT KVM is the escape hatch if unbootable.

The forced-forgetting on reboot is the point: the only way to keep a
fix is to commit it to the repo.

## Updating

`updatectl update host` (add `--reboot` to reboot after), then you're
on the new version. `updatectl list host` shows versions; roll back by
picking an older UKI in the systemd-boot menu. No wrapper, no auto-
updates. Signatures aren't checked (`Verify=no` in the transfer files
— LAN trust boundary; the SHA256 manifest is still enforced).

Two persist chores that sysupdate can't do itself (it doesn't know
about `@persist`) run at boot instead:

- **Per-version persist fork** — the initrd forks `@persist/<v>` for a
  newly-installed version from the previous boot's persist. See Boot
  sequence.
- **Orphan persist GC** — `theatre-os-persist-gc.service` reaps any
  `@persist/<v>` whose `@os/<v>` sysupdate has swept. Bare versions
  only; never snapshots / restore backups / experiment scratch.

## The `theatre-os` CLI

Single entry point for the OS-state operations that go beyond plain
systemd tooling: persist snapshots/restore and experiment mode.
Sources under `mkosi.extra/usr/lib/theatre-os/cmd-*.sh`.

| Command | What it does |
|---|---|
| `theatre-os experiment` | Enter experiment mode live: swap-snapshot `@os/<v>` and `@persist/<v>`, flip `/` to RW. Reboot to leave. |
| `theatre-os snapshot [name]` | Snapshot `@persist/<v>` to a checkpoint before risky persist mutations. |
| `theatre-os snapshot list` | Show manual snapshots. |
| `theatre-os snapshot delete <id>` | Drop a manual snapshot. |
| `theatre-os snapshot prune` | Drop snapshots older than 30 days, with confirm. |
| `theatre-os restore <id>` | Stage a snapshot as the next boot's persist (live swap); reboot to apply. |

`experiment` and `restore` share one trick: **btrfs subvolume mounts
are inode-tracked, not path-tracked**. Renaming a subvolume doesn't
disturb the live mount, so we rename the current `@os/<v>` (or
`@persist/<v>`), snapshot it back to the original name (RW or RO as
needed), and the kernel still serves the running system from the
renamed copy. Next boot mounts the fresh subvol. Verified across
`mount -o remount,rw /` on the RW-flipped current subvol;
end-to-end test in `tests/cases/03-experiment.sh`.

## Layout

Single GPT on the internal NVMe, two partitions:

```
Part 1: ESP             2 GiB    vfat    GUID: ESP                   label: ESP
Part 2: theatre-os-data rest     btrfs   GUID: Linux generic data    label: theatre-os-data
```

The btrfs partition holds both OS and persist subvolumes:

```
/                                          (partition root, never mounted as /)
├── @os/2026-05-09-1422
├── @os/2026-05-09-1530
├── @os/2026-05-10-0901                    RO, written by sysupdate
├── @persist/2026-05-09-1422
├── @persist/2026-05-09-1530
├── @persist/2026-05-10-0901               RW, one per OS version, CoW-shared
└── last-booted-version                    plain file: last version booted
```

(`@persist/` may also hold sibling subvols from the CLI:
`<v>-snap-<ts>` checkpoints, `<v>-pre-restore-<ts>` backups,
`<v>-experiment-<u>` scratch. Those have their own lifecycles and are
never touched by the orphan GC.)

`last-booted-version` sits at the btrfs root (not inside any subvol)
so it survives per-version swaps; the initrd reads it to fork a new
version's persist and rewrites it each boot (see Boot sequence).

One partition (vs two) so free space flows between OS and persist.
Per-version persist isolation means rollback also rolls back persist
state — no half-bricked Kodi DB after rolling back across a schema
migration. CoW makes per-version persist nearly free in space.

ESP is oversized at 2 GiB. UKIs are ~107 MB; with `InstancesMax=10`
retention that's ~1 GB used. Headroom for recovery / debug variants.
`KernelInitrdModules=default` in `mkosi.conf` keeps the initrd small
— without it, mkosi bundles every module + firmware blob and the UKI
balloons to ~440 MB.

The data partition has a pinned PARTUUID
(`78332b2c-d061-488f-8f21-41f3fa97226a` in
`mkosi.repart.in/10-data.conf.in`). The initrd looks it up via
`/dev/disk/by-partuuid/` and mounts the right `@os/<v>` and
`@persist/<v>` based on the `IMAGE_VERSION` baked into the UKI's
`/usr/lib/os-release`. Same image works on any host whose data
partition uses the pinned PARTUUID; install re-asserts it.

Version stamp = build datetime, UTC, minute resolution
(`2026-05-09-1422`). Sorts correctly as a plain string (sysupdate's
`@v` matching is lexicographic). The executable `mkosi.version` in
the repo prints `date -u +%Y-%m-%d-%H%M`; mkosi reads its stdout and
flows it into artefact filenames + `/usr/lib/os-release`'s
`IMAGE_VERSION`. Git SHA is recorded separately as the
spec-blessed `BUILD_ID=` field.

### What's persistent

- `/var/` — bind-mounted entire from `@persist/<v>/var`. Default
  Linux semantics; services find their state where they expect it.
  The install version's persist is seeded from the rootfs's `/var`
  tree at install time so packages don't silently re-initialise on
  first boot; each later version forks its persist (`/var` included)
  from the previous boot's persist, in the initrd, on its first boot
  (see Boot sequence).
- `/home/kodi/` — bind-mounted, full Kodi userdata + moonlight
  config. Owned by `kodi:kodi` (UID/GID 420, pinned in `sysusers.d/`
  for stability across rebuilds).
- `/etc/machine-id` — bind-mounted single file. Generated on first
  boot by a tiny initrd oneshot if the persist file doesn't exist
  yet. Done in the initrd because PID 1 reads machine-id before any
  rootfs `.mount` unit could run. Standard image-OS pattern.
- sshd host keys: redirected to `/var/lib/ssh/` via a sshd_config
  drop-in (so they ride along on the `/var` bind without needing a
  separate `/etc/ssh/` bind that would hide the rootfs-shipped
  `sshd_config`).

### What's not persistent (deliberately)

- `/etc/` (apart from `machine-id`) — fully baked by mkosi. Edits in
  normal mode fail because `/` is RO. The only way to persist a
  config change is to ship a new image. Forced-forgetting is the
  whole point.
- `/usr/`, `/opt/`, installed packages — part of `@os/<v>`.
- `/run`, `/tmp`, `/dev/shm` — standard tmpfs.

No LUKS. Threat model for a living-room HTPC (physical theft / disk
pull) doesn't justify TPM-sealed-unlock complexity for the data at
risk (watch history, BT pairings, host ssh keys). Revisit if persist
ever holds something genuinely sensitive.

### Userdata: image-scope vs deploy-scope

Two complementary repos:

- **theatre-os (this repo)** — anything reproducible-from-source
  that must survive a wipe-and-rebuild. The image carries
  hardware-coupled Kodi addons + keymaps (lights toggle, watchlist,
  etc.) under `mkosi.extra/usr/share/kodi/`. Kodi reads these as system
  addons; no SQLite registration needed. The AVR volume addon + its
  keymap are `t480`-only, so they live in that profile's overlay
  (`mkosi.profiles/t480/mkosi.extra/usr/share/kodi/`) rather than the
  shared tree; the `zz_` prefix on the AVR keymap forces alphabetical
  load order so its volume-key bindings beat Kodi's built-in
  `keyboard.xml` / `remote.xml`. (The ZBook uses HDMI-CEC for volume,
  handled by Kodi's built-in libcec peripheral — no addon or keymap.)
- **ha-config** — anything per-user / stateful / secret. HAKA + its
  HA token, SkinShortcuts menu config (user-edited via the UI),
  Kodi library + watch state + skin choice + instance UUID. Deployed
  by `ha-config/kodi/deploy.sh` against `/home/kodi/.kodi/` on the
  persist subvol. Safe to run any time — mutates persist like Kodi
  itself does. For risky deploys, `theatre-os snapshot` first.

The Kodi instance UUID in `~/.kodi/userdata/guisettings.xml` is what
HA's `media_player.theatre` keys off. At any machine cutover, copy
that file into the new persist before first Kodi launch — otherwise
HA recreates the entity with a new ID and breaks ~5 automations.

## Hardware

Two boxes, one per mkosi profile (see "Profiles (per-machine
targets)"). Per-box hardware quirks are isolated in the profile — never
in shared config — so one box's workaround can't regress the other.

The `t480` (main theatre) is a Lenovo ThinkPad T480 — see
`t480-hardware-quirks.md`: AMT provisioning + hostname-sharing DNS
quirk, eDP-1 disable for external display, HDMI 1.4 cap forcing USB-C
DP-alt for 4K60. The `zbook` (bedroom TV) is an HP ZBook whose quirks
are still being characterised — see `zbook-hardware-quirks.md`. When
adapting to other hardware, expect to grow that doc: ALSA card naming,
display output selection, kernel modules to add to the initrd, etc.

Battery: the `t480` profile pins charge to 40-60% via a udev rule for
an always-plugged-in machine. Rationale in
`mkosi.profiles/t480/mkosi.extra/usr/lib/udev/rules.d/50-charge-thresholds.rules`.
The ZBook may need its own rule (HP EC exposes charge control
differently, if at all).

## Kodi & moonlight

Kodi runs gbm-direct (no compositor → refresh-rate switching works,
HDR / 10-bit passthrough works on the open driver stack).
moonlight-qt runs as a wayland client under a minimal sway session,
launched from inside Kodi for game streaming. sway-not-EGLFS because
Qt EGLFS adds ~one frame of compositor latency on Intel iGPUs
(12-17ms → 2-6ms render-incl-vsync on T480 UHD 620 after the
switch). Full detail + measurements in the
`theatre-os-moonlight.service` header; sway tunables in
`mkosi.extra/etc/sway/config`.

### Display ownership: stop-and-start handoff

Only one process can hold DRM master at a time, and Kodi-gbm does
NOT release it on VT switch (confirmed by Kodi upstream — forum tid
373067 — and validated on hardware: `chvt 2` + launching moonlight
gets `Permission denied` on every page flip while Kodi is still
master). So moonlight launching = stop kodi entirely (close()s the
DRM fd, kernel revokes master), run moonlight, restart kodi.

- `kodi-gbm.service` runs on tty1, holds DRM master while active.
- `theatre-os-moonlight.service` has `Conflicts=kodi-gbm.service`
  (starting moonlight auto-stops Kodi) and `ExecStopPost=+systemctl
  --no-block start kodi-gbm.service` (moonlight exiting brings Kodi
  back). `--no-block` avoids the obvious deadlock; the `+` prefix
  runs as root so it can manage system units despite `User=kodi`.
- The kodi user can `systemctl start theatre-os-moonlight.service`
  without auth via a narrowly-scoped polkit rule at
  `mkosi.extra/etc/polkit-1/rules.d/`.

Cost: ~5s of black screen each transition. Fine for once-per-
gaming-session, not for per-frame.

### Audio

ALSA-direct for both Kodi and moonlight. **No PipeWire, no
PulseAudio, no audio daemon.** Mirrors LibreELEC. Only path that
reliably handles bitstream passthrough for lossless TrueHD / DTS-HD
MA / Atmos-as-TrueHD (typical UHD Blu-ray rips); PipeWire still
lists those formats as "doesn't work yet in practice" as of 1.6.4.

`/etc/asound.conf` routes the `default` PCM through dmix to the HDMI
sink so Kodi's nav-sound effects can mix with main playback, and so
moonlight (which opens `default` and has no device picker) reaches
HDMI. Kodi's bitstream passthrough addresses the hw device
explicitly and bypasses dmix entirely. Card identifier is `CARD=PCH`
(name-based, stable across dock changes), not numeric. Full
rationale in the asound.conf header.

Trade-off: no Bluetooth audio output. Acceptable for a couch-AVR
HTPC.

### Recovery channel

When Kodi gets confused by a display-state change (projector off at
boot, AVR HDMI mode switch) and the on-screen UI is unusable, a
wall-mounted HA tablet can force a Kodi restart without needing SSH
or AMT. systemd-socket-activated TCP listener on port 9091; each
connection spawns a fresh `Accept=yes` oneshot handler that reads
one line, runs the action, writes one line back. Three files +
~30 lines of shell, no auth code, no HTTP framework.

Protocol: `PING → PONG`, `RESTART → OK | FAIL exit=N <err>`,
anything else → `FAIL unknown command`. Trust model: anyone on the
LAN can issue commands; blast radius is one forced Kodi restart.
Doesn't help if the box is kernel-wedged — fall back to the dock's
physical power button.

### AVR event logger

**`t480` profile only** — the bedroom ZBook has no Denon AVR (volume
runs over HDMI-CEC there), so this ships only in the `t480` image
(`mkosi.profiles/t480/mkosi.extra/`).

`theatre-os-avr-logger.service` holds a persistent TCP control
session to the Denon AVR on port 23 and timestamps every
state-change event the receiver pushes (input switch, surround
mode, audio format, HDMI input/output resolution, etc.) into the
journal. Purpose is diagnostic correlation against Kodi: when a
playback stall appears in `~kodi/.kodi/temp/kodi.log` as
`OutputPicture - timeout waiting for buffer`, the AVR-side log
tells us whether the HDMI link to the projector renegotiated
(`SSINFSIGRES O...` changes → projector-cable issue), the HTPC
input renegotiated (`SSINFSIGRES I...` / unexplained audio
events → HTPC→AVR link), or nothing changed at all (issue is
upstream of HDMI — GPU bottleneck or Kodi bug).

Pure async, no polling: the AVR pushes one CR-terminated line per
state change on its own. We send a single `PW?` at connect time so
the journal records a sign-of-life before the AVR goes quiet. TCP
keepalive is on so a half-open socket (post-suspend, NAT timeout)
gets detected within a few minutes instead of blocking forever in
`recv()`. On any socket error the script exits non-zero and
systemd's `Restart=on-failure` + `RestartSec=10s` handles the
reconnect.

View: `journalctl -u theatre-os-avr-logger -f`. Correlate:
`journalctl -u theatre-os-avr-logger --since '2h ago'` alongside
`grep OutputPicture ~kodi/.kodi/temp/kodi.log`.

## Boot sequence

UEFI → systemd-boot → selected UKI bundles kernel + initrd → the
initrd's systemd PID 1 mounts `@os/<v>` RO at `/sysroot`, mounts the
btrfs root (subvolid=5) at `/sysroot/system/data` so it can see the
`@persist/` container + `last-booted-version`, runs the
persist-snapshot step (below) to ensure `@persist/<v>` exists, mounts
that `@persist/<v>` at `/sysroot/system/persist`, binds `/sysroot/var`,
`/sysroot/home/kodi`, and `/sysroot/etc/machine-id` from persist (all
before switch-root, because PID 1 in the rootfs reads machine-id very
early and a rootfs-side bind would attach too late), then
switch-roots. The rootfs's PID 1 inherits those mounts and brings up
the explicit `efi.mount` that `systemd-gpt-auto-generator` is disabled
from auto-mounting (the generator hangs `initrd-root-fs.target`
waiting for a discoverable root partition we don't have; cmdline has
`rd.systemd.gpt_auto=0`). `kodi-gbm.service` lands the user at Kodi on
tty1 via `Alias=display-manager.service` pulled by `graphical.target`.

### Persist snapshot in the initrd

Between mounting the btrfs root and mounting `@persist/<v>`,
`theatre-os-persist-snapshot.service` runs
`/usr/lib/theatre-os/snapshot.sh` to guarantee `@persist/<v>` exists:
if it doesn't, fork it from `@persist/<last-booted-version>` (or, on a
brand-new box, empty), then record the version booted. Full case
analysis and the crash-safety argument live in `snapshot.sh`; the key
property is that forking happens *here*, in the next boot's initrd
after the previous boot cleanly shut down, so persist is always forked
from a settled state — and sourcing from `last-booted-version` (not
"newest") makes rollback-then-forward fork from the right line.

The initrd's mount units, this service + `snapshot.sh`, and the
machine-id oneshot live in `mkosi.images/initrd/mkosi.extra/`.
`mkosi.finalize` substitutes `@VERSION@` into the `.mount` units
(failing the build if any placeholder survives); `snapshot.sh` reads
`IMAGE_VERSION` from os-release at runtime instead. Each UKI ships its
own version-pinned mounts, so booting an older UKI mounts its matching
`@os/<v>` / `@persist/<v>`.

## Build & publish

```sh
# Default profile is t480 (the main theatre box):
./build.sh                     # build t480 (default verb)
./build.sh -f vm               # rebuild t480 and boot in qemu
./build.sh shell               # nspawn into the rootfs without booting
./publish.sh                   # PUT t480's .tar + .efi + SHA256SUMS to dufs
./vacuum.sh [N]                # trim t480's dufs dir to last N (default 20)

# The bedroom ZBook is the `zbook` profile:
./build.sh --profile=zbook     # build the bedroom-tv image
./publish.sh zbook             # PUT to dufs/bedroom-tv
./vacuum.sh zbook [N]          # trim bedroom-tv's dufs dir
```

All profiles share one `mkosi.output/`, and each
`publish.sh`/`vacuum.sh` targets the matching dufs device path — so
build+publish one target before building the other (see "Profiles
(per-machine targets)").

**Always invoke via `build.sh`, never `sudo mkosi` directly** —
`build.sh` renders `mkosi.repart.in/*.in` templates first (mkosi
doesn't preprocess repart configs, so a direct `mkosi` call uses
stale ones). Output to gitignored `mkosi.repart/`.

mkosi does almost everything else: `Format=disk` + `SplitArtifacts=
uki,tar` + `Checksum=yes` produces the `.raw`, `.tar`, `.efi`, and
`SHA256SUMS` in one pass. We override `UnifiedKernelImageFormat=%i_%v`
so the install-time UKI matches sysupdate's expected filename
pattern (default `&e-&k` would leave an orphan UKI that
`InstancesMax` retention can't see).

Test harness: `./tests/run.sh` boots the just-built image in qemu
and runs end-to-end cases against the `theatre-os` CLI verbs. See
`TESTING.md`.

## Install

The same build's `.raw` artefact is bootable install media. `dd` it
via AMT KVM + a USB rescue env. First boot, `systemd-repart` grows
the data partition to fill the disk and creates `@os/<v>` and
`@persist/<v>` from the install-time configs.

```
dd if=theatre-os_<v>.raw of=/dev/nvme0n1 bs=4M status=progress
sync
reboot
```

The `.raw` stays on the build host; `publish.sh` filters it out of
the dufs upload (install is rare, updates aren't). Same image is
also the recovery tool: if persist is unrecoverable, `dd` again.
Persist data is lost but recoverable from HA backups via `ha-config`.

## Rejected alternatives

OS-level:

- **Stay on LibreELEC** — moonlight-qt addon couldn't get HW decode
  on Generic; Legacy build = X11 = rotting.
- **Silverblue / Bazzite / Kinoite** — bundled DE bloat, designed
  for desktops, fights the grain for Kodi-as-shell.
- **NixOS** — too unfamiliar; AI-generated Nix is hard to review
  safely.
- **Arch + Ansible + overlayroot** — simpler but loses real image
  reproducibility and atomic OS rollback.

Boot / storage:

- **Strict A/B partitions** — only 2 rollback slots; N subvols gives
  unlimited rollback bounded by retention.
- **GRUB + grub-btrfs** — solves dynamic menu regen, which we don't
  need: the OS subvol (`@os/<v>`) is created only on update and
  sysupdate drops its UKI in the same transaction. systemd-boot's
  static UKI enumeration is enough.
- **erofs files on ext4** (KDE Linux model) — equivalent isolation
  but adds a loop-mount layer; btrfs RO snapshots give the same
  immutability natively. We also don't need delta downloads, so the
  erofs+desync motivation doesn't apply.
- **Kernel inside the snapshot** — would force GRUB onto the boot
  path (systemd-boot can't read a kernel out of a subvol). Atomicity
  comes from sysupdate dropping snapshot + UKI in one transaction
  anyway.
- **`btrfs send` streams** — sysupdate's source types don't consume
  them; tar-into-subvol gives the same end state with simpler
  plumbing and a non-btrfs build host.
- **GPG-signed updates** — single-tenant LAN inside one trust
  boundary; HTTPS + SHA256SUMS covers transport corruption. Add
  later if updates ever leave the homelab.
- **LUKS / TPM-sealed unlock** — see "What's not persistent".

Display / audio:

- **Kodi-on-wayland** — would lose refresh-rate / HDR switching on
  the open driver stack today. moonlight gets a compositor (sway)
  because it specifically benefits; Kodi doesn't.
- **cage instead of sway for moonlight** — works architecturally but
  swallows stderr (no journal output during debugging), smaller
  userbase. Sway's overhead is ~2k LoC of unused features.
- **Kodi-on-X11** — DRM master releases cleanly on VT switch, but
  Kodi-x11 loses HDR / 10-bit passthrough on the open driver stack.
- **PipeWire / PulseAudio** — bitstream passthrough for lossless
  TrueHD / DTS-HD MA still doesn't work reliably; mixing reliable +
  unreliable formats in one stack is asking for couch debugging.
  Trade-off: no Bluetooth audio output. Fine for couch-AVR.
- **In-process Kodi watchdog reading evdev for the recovery
  channel** — Kodi-gbm grabs every input device exclusively via
  libinput's `EVIOCGRAB` and no other reader sees the events. No
  runtime toggle. (See git history for the reverted attempt.)
- **SSH from HA with `command=` key restriction for the recovery
  channel** — works but introduces an SSH key to manage and
  host-key drift across image rebuilds. The socket approach has
  neither.

## Future work

- **Boot-health telemetry** — post-boot script snapshotting
  `systemctl --failed` + journal error counts per boot, exported to
  HA or a flat file. Cheap to build, big win for "did that update
  actually work?" without SSHing in. Punt until enough boot history
  to want it.
- **Auto-rollback via `systemd-bless-boot`** — same mechanism KDE
  Linux uses. Skipped while there's one HTPC and the human pushing
  updates is the one watching them.
