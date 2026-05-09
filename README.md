# theatre-os

Declarative, image-based OS for the home theatre HTPC. Replaces
LibreELEC with a modern, reproducible build. Kodi is the shell;
moonlight-qt launches from within Kodi for game streaming.

## Architecture

- **Build**: [`mkosi`](https://mkosi.systemd.io/) produces an Arch-based
  root tree from declarative config in this repo. Build output per
  release: `theatre-os_<v>.tar.xz` (root tree) + `theatre-os_<v>.efi`
  (matching UKI) + `SHA256SUMS`.
- **Distribution**: uploaded via WebDAV PUT to the homelab dufs
  instance at `push.apps.lasath.com/theatre-t480/`, served read-only
  via HTTPS at `static.apps.lasath.com/sysupdate/theatre-t480/`. LAN-only
  DNS, real Let's Encrypt cert. No GPG signing — single-tenant LAN, the
  build host and image host are inside the same trust boundary;
  HTTPS + SHA256SUMS catches transport corruption and is the realistic
  threat. (Adding signing later is a non-breaking change if needed.)
- **Deploy**: [`systemd-sysupdate`](https://www.freedesktop.org/software/systemd/man/latest/systemd-sysupdate.html)
  on the HTPC pulls each release over HTTPS. The transfer manifest has
  two entries: the `.tar.xz` is extracted (`Type=url-tar`) into a fresh
  btrfs subvolume on the rootfs partition (`Type=subvolume`); the `.efi`
  UKI is dropped into `/efi/EFI/Linux/` (`Type=regular-file`).
  systemd-boot enumerates UKIs → boot menu shows every installed
  version. Rollback: pick an older entry. Old subvolumes + UKIs are
  GC'd by sysupdate retention policy (keep N).
- **Runtime**: RO `@os/<v>` btrfs subvolume mounted directly at `/` —
  no overlayfs. Writes to `/usr` and most of `/etc` fail loudly,
  enforcing the discipline that config changes must be promoted to
  the mkosi config. `/var`, `/home/kodi`, and a few `/etc` identity
  files are bind-mounted from a per-version persist subvolume
  (`@persist/<v>`). Experiments use a separate boot mode that
  snapshots `@os/<v>` and `@persist/<v>` to writable throwaway
  subvolumes — see "Updates & experiment mode".
- **Display**: Kodi runs gbm-direct (no compositor → refresh-rate
  switching works). moonlight-qt launches via Qt EGLFS/KMS, also
  compositor-free. Quit-and-relaunch handoff between them, same as
  LibreELEC.

Reference implementations:
- [`systemd/particleos`](https://github.com/systemd/particleos) — mkosi
  + sysupdate + UKI patterns.
- KDE Linux — UKI + systemd-boot + sysupdate-driven image distribution
  on Arch. They use a *different* on-disk model (erofs files in a
  shared btrfs subvol, single shared persist, hash-tracked etc-merge
  via [`etc-factory`](https://invent.kde.org/kde-linux/etc-factory))
  to enable delta downloads via desync. We don't need delta downloads
  and want stronger per-version isolation than they have, so we differ
  on storage layout — but the UKI/sysupdate/bootflow patterns are
  borrowed from them.

### Why this layout — alternatives we rejected

- **Not strict A/B partitions**: only 2 rollback slots. If push-a-fix
  also breaks, you can't go back two. N snapshots gives unlimited
  rollback depth, bounded only by retention policy + disk.
- **Not GRUB + grub-btrfs**: that pattern (Snapper/openSUSE) exists
  because mutable distros create snapshots unpredictably and need
  dynamic menu regeneration. We create snapshots only on update, so
  sysupdate can drop the UKI in the same transaction. systemd-boot's
  static UKI enumeration is enough; no `grub.cfg` regeneration script,
  no GRUB on the boot path.
- **Kernel in UKI, not inside the snapshot**: atomicity comes from
  sysupdate creating snapshot+UKI together, both signed by the same
  build. Putting the kernel physically inside the snapshot would
  require GRUB to read it out (the only thing systemd-boot can't do).
  Not worth the complexity.
- **Not erofs image files on ext4**: equivalent N-slot capability, but
  loop-mounting an image inside initrd adds a layer over a plain btrfs
  subvol mount. btrfs RO snapshots give the same immutability guarantee
  erofs would.
- **Not `btrfs send` streams**: sysupdate's source types don't natively
  consume `btrfs send` output; its btrfs support is target-side
  (`Type=subvolume`). A tar extracted into a fresh subvolume gives us
  the same end state with simpler plumbing — the build host doesn't
  even need to be btrfs, and tars are trivially reproducible. We lose
  cross-version CoW dedup on disk; for ~2GB images on an SSD, irrelevant.
- **No update signing (yet)**: GPG/key management for one LAN box with
  a single trust boundary is ceremony without a matching threat. HTTPS
  + SHA256SUMS covers the realistic risk (transport corruption,
  accidental wrong-file). Revisit if we ever expose updates publicly or
  share with another machine outside the homelab.

## Hardware

The HTPC is a **Lenovo ThinkPad T480** (during staging at
`192.168.0.78`, post-cutover takes over `theatre.home.lasath.com`
from the existing LibreELEC ZBook). Has Intel vPro / AMT for OOB
recovery — see `ha-config/t480-hardware-quirks.md`.

The current production box (HP ZBook Firefly 14 G7 running LibreELEC)
gets unplugged from the AV setup at cutover. theatre-os is **not**
intended to run on it. `ha-config/zbook-libreelec-tweaks.md` is kept
as a reference for the *behaviours* (BT wake, WOL, power-key
handling, wake chime, sleep mode) that need to keep working post-
cutover, but most of the *implementation* tweaks in that doc are
dock/USB-NIC specific to the ZBook and don't necessarily apply.

## Iteration loop

1. SSH into the box. By default `/` is RO — `pacman -S` and `/etc` edits
   fail loudly. This is correct: writes here aren't supposed to be
   ephemerally easy.
2. `theatre-os experiment` to enter experiment mode live (no reboot;
   btrfs swap-snapshot trick). Now `pacman -S` / `/etc` edits work
   and land in throwaway subvols.
3. `theatre-os experiment-off` (or reboot) → experimental writes vanish.
4. Promote working changes into the mkosi config in this repo
   (`mkosi.conf`, `mkosi.extra/`, `mkosi.images/`, etc.).
5. `mkosi build` → `./scripts/publish.sh` → `theatre-os update` on
   the box, reboot.
6. Verify; if broken, reboot and pick the previous UKI from the
   systemd-boot menu (or recover via AMT KVM if unbootable).

The forced-forgetting on reboot is a feature: the only way to keep a
fix is to commit it to the repo.

## Accounts & remote access

Two accounts exist on the running system:

- **`root`** — administration. SSH login is the only access path; key
  auth only, password auth disabled. The authorised pubkey lives in
  this repo at `mkosi.extra/root/.ssh/authorized_keys` (public by
  design) and is baked verbatim into the RO root by mkosi at the same
  path. Rotating the allowed key = edit the file in this repo and
  ship a new image. There is no per-host customisation; one image,
  one key.
- **`kodi`** — service account created by Arch's `kodi-standalone-service`
  package. Runs Kodi (and moonlight-qt invoked from it). Member of
  `audio video input render wheel network`. No login shell, no SSH.
  Userdata at `/home/kodi/.kodi/` is on the persist subvol.

Out-of-band recovery: Intel AMT (KVM + SOL) on the T480.
See top-level `AGENTS.md` for credentials.

The kernel cmdline includes `console=tty0 console=ttyS0,115200` so
that AMT's Serial-over-LAN sees kernel + systemd output during boot
and any panic. Kodi runs on tty1 and is unaffected. (AMT SOL only
shows kernel onward, not pre-kernel firmware/POST — for those, use
AMT KVM. See `ha-config/t480-hardware-quirks.md`.)

## Versioning

Image version = build datetime, UTC, minute resolution: `2026-05-09-1422`.

- Sorts correctly as a plain string (sysupdate's `@v` matching is
  lexicographic, not version-aware), so newest builds always win.
- No external counter to maintain — the build script just stamps
  `date -u +%Y-%m-%d-%H%M`. Practically never collides.
- Human-readable in the systemd-boot menu: you can tell at a glance
  which entry is newer when troubleshooting.
- Git SHA is recorded separately in `/etc/os-release` (`THEATREOS_GIT_SHA=`)
  for source traceability. The version itself doesn't embed the SHA
  because SHAs don't sort meaningfully.

Artifacts use the version as their stem:
`theatre-os_2026-05-09-1422.tar.xz`, `theatre-os_2026-05-09-1422.efi`.

## Partition layout

Single GPT on the internal NVMe, two partitions:

```
Part 1: ESP             2 GiB    vfat    GUID: ESP                   label: ESP
Part 2: data btrfs      rest     btrfs   GUID: Linux generic data    label: theatreos-data
```

The btrfs partition holds **both** OS and persist subvolumes:

```
/                                            (btrfs partition root, never mounted as /)
├── @os/2026-05-09-1422
├── @os/2026-05-09-1530
├── @os/2026-05-10-0901                       (RO subvols, written by sysupdate Type=subvolume)
├── @persist/2026-05-09-1422
├── @persist/2026-05-09-1530
├── @persist/2026-05-10-0901                  (RW subvols, one per OS version, CoW-shared)
└── @persist/seed                             (initial empty/baked persist, used on very first boot)
```

One btrfs (vs two separate partitions for OS and persist) keeps free
space flowing freely between them and simplifies the GPT. The blast
radius of fs corruption covers both, but recovery requires AMT KVM +
USB rescue regardless, so the isolation argument is weak.

ESP is oversized at 2 GiB (UKIs are ~50–100 MB, retention ~10 versions
= <1 GiB). Comfortably within FAT32/firmware tolerances; the headroom
exists so we can experiment with alternate boot artefacts (recovery
UKIs, debug variants, multi-profile UKIs) in future without
re-partitioning. Shrinking later is annoying.

No swap (HTPC has ample RAM; swap on btrfs is fiddly). No separate
`/boot` partition — UKIs live directly in the ESP and systemd-boot
enumerates them.

### No encryption

LUKS skipped intentionally. Threat model for a living-room HTPC is
physical theft or disk-pull, in which case the data at risk (Kodi watch
history, BT pairings, host ssh keys) doesn't justify the operational
cost of TPM-sealed unlock — every UKI change re-measures PCRs and the
seal needs refreshing, every firmware update risks bricking the disk.
Revisit if persist ever holds something genuinely sensitive.

### GPT discoverability

ESP is auto-discovered by systemd-boot via its standard GUID. The data
partition uses the standard "Linux generic data" GPT type GUID with the
label `theatreos-data`; the initrd looks it up by label, mounts it,
then mounts the appropriate `@os/<v>` and `@persist/<v>` subvolumes
based on the version stamped into the UKI's `/usr/lib/os-release`.

(Existing files like `/etc/fstab` aren't used for these mounts — the
initrd and a small systemd-mount unit handle them, so the same image
works on any host with a `theatreos-data`-labelled partition.)

## Persistence model

The data partition holds **one persist subvolume per installed OS
version** (`@persist/<v>`), alongside the `@os/<v>` rootfs subvolumes.

`@persist/<v>` is **created at install time of `<v>`**, not at first
boot, by snapshotting `@persist/<currently-running>`. The `theatre-os
update` wrapper does this as part of the install transaction (see
"Updates & experiment mode"). On the very first install there's no
running version to fork from; the installer snapshots a baked-in
`@persist/seed` (skeleton dirs, empty identity files).

Booting `<v>` is therefore a dumb mount: `@persist/<v>` always already
exists. The version stamped into the booted UKI's `/usr/lib/os-release`
selects which subvolume to mount.

`@persist/<v>` is a normal RW subvolume. Writes from a normal boot
land in it directly and survive reboot — standard Linux semantics, no
commit dance. Discipline is enforced on the `/` side via the snapshot
model (see "Updates & experiment mode"), where it actually matters for
reproducibility.

Result: rolling back the OS via systemd-boot also rolls back persist
state, because the older UKI selects the older persist subvol that
forked from the right ancestor. No half-bricked states from e.g. Kodi
DB schema migrations across rollback.

CoW makes per-version persist nearly free in space.

### What's persistent

The whole of `/var` is bind-mounted from `@persist/<v>/var`. We don't
enumerate `/var` subdirs individually; "everything in `/var` persists
by default" matches normal Linux and avoids fighting services that
write somewhere we didn't predict.

Other persist mounts (specific paths outside `/var`):

- `/home/kodi/.kodi/` — Kodi userdata, addons, watch state
- `/etc/machine-id` — generated on first boot, then stable
- `/etc/ssh/ssh_host_*` — generated on first boot, then stable
- (more added during phase 4)

Identity files (machine-id, host keys) are **generated on first boot**,
not baked into the image. The image ships without them; standard systemd
units (`systemd-machine-id-setup`, sshd's keygen) populate them on the
persist subvol the first time the box boots a given OS version. This
keeps the image artifact non-sensitive (no leakable host keys baked
in) and avoids identity collisions if the same image is ever
re-flashed onto a replacement box.

We disable `systemd-coredump` writing coredumps to disk — a
crash-looping service could otherwise fill `/var/lib/systemd/coredump/`
unbounded.

### What's *not* persistent (deliberately)

- `/etc/` (except the few identity files above) — fully baked by mkosi.
  Edits during normal-mode SSH sessions fail loudly (`/` is RO). The
  only way to make a config change stick is to promote it into the
  mkosi config in this repo. KDE Linux makes /etc writable (with a
  hash-tracked merge tool, `etc-factory`, that lets package upgrades
  push new defaults without clobbering user edits) because it's a
  general-purpose desktop where users edit configs by hand; we're a
  sealed appliance and the forced-forgetting is the whole point of the
  iteration loop.
- `/usr/`, `/opt/`, installed packages — RO subvolume.
- `/run`, `/tmp`, `/dev/shm` — standard tmpfs (systemd-managed).

## Updates & experiment mode

Both updates and experiments use the same primitive: **btrfs writable
snapshots of an otherwise-RO source.** No overlayfs anywhere.

The `theatre-os` CLI is the single entry point for all of this:

| Command | What it does |
|---|---|
| `theatre-os update` | Pull the next release: invoke sysupdate, snapshot persist, paired GC. Refuses if in experiment mode. |
| `theatre-os experiment` | Enter experiment mode live (no reboot): swap-snapshot `@os/<v>` and `@persist/<v>`, flip `/` to RW. |
| `theatre-os experiment-off` | Reverse the swap, drop the throwaway, remount RO. Live, no reboot. |
| `theatre-os snapshot [name]` | Manually snapshot persist for a checkpoint before risky persist mutations. |
| `theatre-os snapshot list` | Show manual snapshots. |
| `theatre-os snapshot delete <id>` | Drop a manual snapshot. |
| `theatre-os snapshot prune` | Drop snapshots older than 30 days, with confirm. |
| `theatre-os restore <id>` | Mark a snapshot for restoration on next boot (initrd performs the swap). |

Details for each in the subsections below.

### Normal boot

- `@os/<v>` is RO. Mounted directly at `/`.
- `@persist/<v>` is RW. Mounted (per the persist model above).
- Writes to `/usr` or `/etc` outside identity files **fail loudly**.
  This is the discipline: the only path to changing those is editing
  mkosi config and shipping a new image.
- Writes to `/var`, `/home/kodi/.kodi`, etc. just work and persist.

### Experiment mode

For when you need to `pacman -S foo` on the box to test something
before committing it to mkosi config.

Entered live, no reboot, via `theatre-os experiment`. Exploits the
fact that **btrfs subvolume mounts are inode-tracked, not path-tracked**
— renaming a subvolume doesn't disturb a live mount. Same trick for
both the OS and persist subvols:

```
# For each of: <subvol> = @os/<v>, @persist/<v>
mv  <subvol>  <subvol>-experiment-<unique>     # live mount unaffected
btrfs subvolume snapshot <subvol>-experiment-<unique> <subvol>
                                                # fresh RO snapshot,
                                                # will be mounted on
                                                # next normal boot

# OS only (persist is already RW):
btrfs property set <subvol>-experiment-<unique> ro false
mount -o remount,rw <mountpoint>
```

After this, `/`, `/var`, `/home/kodi/.kodi` etc. are writable. Writes
land in the `-experiment-<unique>` subvols (the ones the kernel still
holds open). The freshly-snapshotted originals sit on disk untouched
until the next boot, which mounts them and resumes normal mode.

A motd / journal banner advertises experiment mode to anyone who
SSHes in. `theatre-os experiment-off` reverses the swap (rename back,
drop the throwaway, remount RO) — also live, no reboot.

If you want to keep something from an experiment: edit the mkosi
config in this repo and ship a new image. Same discipline as the
iteration loop.

**Caveat — needs prototyping in a VM.** The `mount -o remount,rw /`
on a btrfs subvol whose `ro` property was just flipped is the part we
want to verify works cleanly across the kernel versions we'll target.
The mechanism is sound in principle; in practice there may be edge
cases (the kernel may cache RO state somewhere we need to nudge).

Old experiment subvols are retained for forensic browsing (last N
kept, older GC'd).

### `theatre-os update`

A small wrapper around `systemd-sysupdate` that handles the persist
snapshot and the experiment-mode guard. Roughly:

```
theatre-os update:
  1. If running in experiment mode (root mount is on
     @os/<v>-experiment-<u>): refuse and exit.
  2. Determine running version <r> from /etc/os-release.
  3. systemd-sysupdate update      # downloads new tar+UKI, extracts
                                   # to @os/<n>, drops UKI in ESP, GCs old @os
  4. btrfs subvolume snapshot @persist/<r> @persist/<n>
  5. GC orphan @persist/<x> where @os/<x> no longer exists.
  6. Optionally reboot.
```

The experiment-mode guard ensures `@persist/<n>` forks from the
last-known-good persist (the running version's), not from an ephemeral
experiment snapshot that won't exist after the next reboot.

**`systemd-sysupdated` is masked at image build time.** sysupdate ships
both a CLI (`systemd-sysupdate`) and a D-Bus daemon
(`systemd-sysupdated`). The daemon is what tools like Plasma's
Discover, `updatectl`, etc. drive to perform updates. We don't want
that — anything calling the `org.freedesktop.sysupdate1` D-Bus
interface would invoke a sysupdate install directly, bypassing the
`theatre-os update` wrapper and skipping both the experiment-mode
guard and the persist snapshot. So the image masks
`systemd-sysupdated.service` and `dbus-org.freedesktop.sysupdate1.service`.
The CLI is the only entry point. (sysupdate has no native pre/post
hooks — see [systemd#35988](https://github.com/systemd/systemd/issues/35988)
— so a wrapper is the only way to compose snapshot logic with
sysupdate.)

The `systemd-sysupdate.timer` (the periodic auto-update mechanism)
is also masked. Updates happen only when explicitly invoked by
`theatre-os update`, never on a schedule. This is deliberate — an
auto-update at 03:00 that breaks the box is harder to debug than one
the human just pushed.

### Manual persist snapshots: `theatre-os snapshot` / `restore`

The auto per-version persist snapshot (one fork per OS install) is
coarse: it doesn't help if you mutate `~/.kodi/` between OS updates
and want to undo it. Common case: pushing new Kodi addons via
ha-config's `deploy.sh`, then discovering one of them broke the UI.
For these, take an explicit snapshot first.

```
theatre-os snapshot [name]
  Snapshots @persist/<v> to @persist/<v>-snap-<timestamp>[-<name>].

theatre-os snapshot list
  Shows manual snapshots (name, timestamp, on-disk delta size).

theatre-os snapshot delete <name-or-timestamp>
  Drops a snapshot.

theatre-os snapshot prune
  Drops manual snapshots older than 30 days, with confirm.

theatre-os restore <name-or-timestamp>
  Marks the chosen snapshot for restoration on next boot. Reboot to
  apply.
```

Restore is **not live** — too fragile to swap out a mounted persist
subvol while userspace is using files. Instead, the `restore` command
writes a small marker (e.g. `/efi/theatreos/pending-restore`) that the
initrd checks before mounting persist:

1. Read marker.
2. Rename current `@persist/<v>` → `@persist/<v>-pre-restore-<ts>`
   (kept around as an undo of the undo).
3. Snapshot the chosen `@persist/<v>-snap-...` → fresh `@persist/<v>`.
4. Delete marker.
5. Proceed with normal mount.

CoW makes snapshots cheap on disk — slow-changing state like Kodi's
persists very little delta per snapshot. Take them liberally.

This is **complementary to experiment mode**, not a replacement:

- Experiment mode = throwaway scratch for `/usr` / `/etc` writes
  (loud-failure paths in normal mode); both `@os` and `@persist`
  snapshotted at boot.
- Manual snapshots = explicit checkpoint of persist state for risky
  persist-mutating operations (deploy.sh, manual SSH edits, library
  imports).

## Boot sequence

From power-on to a Kodi prompt. Most steps are stock systemd / mkosi
behaviour; the custom pieces are noted.

1. **Firmware → systemd-boot.** UEFI loads systemd-boot from the ESP,
   which enumerates `EFI/Linux/*.efi` UKIs and presents a menu (or
   auto-selects after timeout). The selected UKI bundles kernel +
   initrd; the matching version is stamped into the initrd's
   `/usr/lib/os-release`. *Free.*

2. **Kernel → initrd.** Standard mkosi-built initrd: drivers, udev,
   systemd in initrd context. *Free.*

3. **Mount the data partition.** Initrd finds `/dev/disk/by-label/theatreos-data`
   via udev and mounts the btrfs root at `/sysroot-data` (or similar).
   *Small custom piece*: a mount unit or generator in the initrd.

4. **Resolve which subvolumes to mount.** Read the version from
   `/usr/lib/os-release`. Target subvols are `@os/<v>` and
   `@persist/<v>`. Both pre-existing (created at install time of `<v>`).
   - Pending restore: if `/efi/theatreos/pending-restore` exists, the
     `theatre-os restore` swap is performed before mounting (see
     "Manual persist snapshots").

5. **Mount root and persist.** Mount `@os/<v>` RO as `/sysroot`. Mount
   `@persist/<v>` at `/sysroot/run/persist` (or similar). Bind-mount
   `/sysroot/var` from `<persist>/var`, `/sysroot/home/kodi/.kodi`
   from `<persist>/home-kodi-kodi`, `/sysroot/etc/machine-id` from
   `<persist>/etc-machine-id`, etc. *Custom* `.mount` units shipped in
   the image; mkosi config pre-creates the empty mountpoints in the OS
   tree.

6. **switch-root** into `/sysroot`.

7. **First-boot identity generation.** On a fresh install, the seeded
   persist has empty `/etc/machine-id` and no `/etc/ssh/ssh_host_*`.
   `systemd-firstboot` generates the machine-id; sshd's keygen unit
   generates host keys. Both write to bind-mounted persist paths and
   stick across reboots and OS rollbacks. *Free* (stock systemd) — we
   just need correct ordering (after persist binds, before consumers).

8. **Normal systemd boot.** networkd, sshd, bluetoothd, etc. *Free.*

9. **Kodi starts.** `kodi-standalone-service` (Arch package) launches
   Kodi as user `kodi` against `/dev/dri/card0` via gbm/EGL/KMS, on
   tty1. See "Kodi & moonlight session" below.

### Custom code summary

Initrd: data-partition mount + version-resolution + pending-restore
swap. Image: a handful of bind-mount `.mount` units, a small
`theatre-os` CLI (subcommands: `update`, `experiment`,
`experiment-off`, `snapshot`, `restore`, …), the moonlight launcher
script. No overlayfs, no exotic machinery; total LoC expected to be
small.

## Kodi & moonlight session

Kodi is the shell. moonlight-qt is launched from inside Kodi for game
streaming and gives the display fully back to Kodi when the user quits
moonlight. Both run compositor-free (gbm/EGLFS direct to KMS) so
refresh-rate and HDR switching work, matching LibreELEC's behaviour.

### Display ownership: VT switching

Only one process at a time can hold DRM master on `/dev/dri/card0`,
which means Kodi-gbm and moonlight-qt cannot share the screen. The
solution is the standard Linux **virtual terminal switching** dance:

- Kodi runs on **tty1** as a system service (`kodi-standalone-service`,
  Arch package, runs as user `kodi`). Holds DRM master while the
  active VT is tty1.
- moonlight-qt runs on **tty2**, launched on demand. The kernel revokes
  Kodi's DRM master when the active VT changes; moonlight takes it.
- When moonlight exits, the launcher switches back to tty1; Kodi
  re-acquires DRM master and resumes drawing.

This is the same pattern X-on-tty7 used for years; mature, known to
work. Kodi-gbm v20+ handles DRM master loss/regain gracefully.

### Launcher

A shell script `/usr/bin/theatreos-launch-moonlight` shipped in the
image:

```
#!/bin/sh
trap 'chvt 1' EXIT INT TERM
chvt 2
exec moonlight-qt …  # Qt EGLFS env vars set as needed
```

Triggered from inside Kodi via a Python addon (lives in the
`ha-config/kodi/` repo, *not* this one — userdata is HA-config scope,
not OS-image scope). The addon is just `subprocess.Popen` of the
launcher script.

### Audio

**ALSA-direct for both Kodi and moonlight. No PipeWire, no PulseAudio,
no audio daemon at all.** This mirrors LibreELEC's setup and is the
only path that reliably handles bitstream passthrough for **lossless
formats — Dolby TrueHD, DTS-HD MA, and Atmos delivered as TrueHD+JOC**
(typical of UHD Blu-ray rips). PipeWire's own current docs (1.6.4,
mid-2025) still list `truehd-iec61937` and `dtshd-iec61937` as
"doesn't work yet in practice." Lossy passthrough (DD, DD+, DTS,
Atmos-as-DD+) does work on PipeWire, but mixing reliable + unreliable
formats in the same stack is asking for couch debugging.

Configuration:
- Kodi: `AE_SINK=ALSA`, audio device set to the HDMI sink directly
  (`hw:CARD=HDMI,DEV=0` or whatever the AVR outputs as).
- moonlight-qt: also via ALSA (Qt audio backend forced to ALSA, not
  PulseAudio compat).

ALSA hardware devices don't support concurrent access, so the
VT-switch handoff covers audio for free: whoever owns the active VT
holds the HDMI device. Kodi releases it on switch-away, moonlight
takes it; reverse on switch-back.

Trade-off: no Bluetooth audio output (PipeWire is the modern BT audio
stack). Acceptable for a couch-AVR HTPC. If we ever wanted BT headphones,
we'd add PipeWire alongside but Kodi/moonlight would still bypass it.

### Userdata: addons, skin, keymaps, settings

theatre-os ships **no** Kodi customisations. The OS provides Arch's
`kodi-standalone-service` package and a writable `/home/kodi/.kodi/`
mountpoint (bind-mounted from `@persist/<v>`); everything inside that
directory — addons (`service.avr.volume`, `script.theatre.lights.toggle`,
`plugin.video.watchlist`, `context.go.to.show`, HAKA, etc.), the
Arctic Zephyr modded skin, keymaps, library, watch state, the Kodi
instance UUID — is owned by `ha-config/kodi/` and pushed to the box
by `ha-config/kodi/deploy.sh`.

This is a deliberate split:

- **theatre-os**: Kodi the engine + the gbm/EGL/KMS plumbing + the
  moonlight launcher script. Reproducible from this repo alone.
- **ha-config**: which addons are installed, what the menu looks
  like, where the AVR is, which lights to toggle on credits.
  Reproducible from ha-config alone.

`deploy.sh` writes to `/home/kodi/.kodi/` (was `/storage/.kodi/` on
LibreELEC); needs path + SSH endpoint update at cutover. Its
SQLite-poke into `Addons33.db` (to mark deployed addons enabled)
keeps working unchanged.

Because `~/.kodi/` lives on persist, `deploy.sh` doesn't intersect
with the image/snapshot machinery: it just mutates the per-version
persist subvol like Kodi itself does. Safe to run any time. For
risky deploys, take a `theatre-os snapshot` first (see
"Manual persist snapshots" above).

Notable: the **Kodi instance UUID** in `~/.kodi/userdata/guisettings.xml`
is what HA's `media_player.theatre` keys off. At cutover (ZBook →
T480), copy `userdata/guisettings.xml` from the ZBook into the T480's
persist before first Kodi launch — otherwise HA recreates the entity
with a new ID and breaks ~5 automations + the `media_player.theatre`
device automations.

### Risks to verify on real hardware

- Kodi's behaviour on DRM master loss (should be clean; verify).
- moonlight-qt EGLFS picking the right tty + DRM card (set
  `QT_QPA_EGLFS_KMS_CONFIG` JSON if it doesn't auto-detect).
- moonlight-qt forced to ALSA backend (Qt may default to PulseAudio
  compat; need to set `QT_MEDIA_BACKEND` or equivalent).
- HDMI device exclusive-access handoff between Kodi and moonlight
  across the VT switch.
- HDR / refresh-rate state restoration when control returns to Kodi
  (moonlight may have changed the mode mid-stream).

## Build & publish

mkosi does almost everything. Two small wrapper scripts in this repo
glue the version-stamp + upload steps around it.

### What mkosi produces for us

With `Format=tar`, `CompressOutput=xz`, `SplitArtifacts=uki`,
`Checksum=yes`, and `ImageVersion=` set from `mkosi.version`, one
`mkosi build` invocation produces:

```
mkosi.output/
  theatre-os_<v>.tar.xz       # rootfs (sysupdate Type=url-tar input)
  theatre-os_<v>.efi          # UKI (sysupdate Type=url-file input)
  theatre-os_<v>.SHA256SUMS   # checksums covering both
```

Notably we **do not** need to:
- Tar the rootfs ourselves (`Format=tar`).
- Run `ukify` separately (`Bootloader=systemd-boot` + `SplitArtifacts=uki`).
- Hash the artefacts (`Checksum=yes`).
- Stamp the version into multiple places (`ImageVersion=` flows into
  the artefact filenames *and* the rootfs's `/usr/lib/os-release`
  *and* the initrd's `/usr/lib/os-release`).

mkosi and sysupdate are designed to compose; we lean on that.

### Version stamping

`mkosi.version` is **executable** in this repo:

```sh
#!/bin/sh
exec date -u +%Y-%m-%d-%H%M
```

mkosi runs it on every build and uses stdout as `ImageVersion=`. That
value flows into the artefact filenames *and* `/usr/lib/os-release`'s
`VERSION_ID=` in both the rootfs and the initrd image. One source of
truth, no external stamping step.

### Kernel cmdline is generic

The cmdline is the same string in every UKI we build (currently
something like `quiet rw console=tty0 console=ttyS0,115200` —
see Accounts & remote access for the SOL rationale). The version
flows from `mkosi.version` into the artefact filenames *and* into
`/usr/lib/os-release`'s `VERSION_ID=` in both the rootfs and the
initrd image; the initrd reads it from there to pick `@os/<v>` /
`@persist/<v>`. Same pattern as KDE Linux's mount-generator.

### Building

```
mkosi build
```

That's the build. mkosi handles tar, UKI splitting, compression,
SHA256SUMS, version stamping. `mkosi.output/` is cleaned on each
build, so it always contains exactly one version's artefacts.

### `scripts/publish.sh`

Discovers the version from the local SHA256SUMS file (mkosi just wrote
it; we don't need to ask mkosi.version again). Fetches the existing
master SHA256SUMS from dufs (if any), appends our entries, uploads
everything. Order matters: SHA256SUMS last so consumers don't see a
stale checksum file mid-upload.

```sh
#!/bin/sh
# usage: publish.sh
set -eu
PUSH="https://push.apps.lasath.com/theatre-t480"
PULL="https://static.apps.lasath.com/sysupdate/theatre-t480"

# Local SHA256SUMS lists exactly what mkosi built this run.
LOCAL_SUMS="$(ls mkosi.output/theatre-os_*.SHA256SUMS)"

# Upload artefacts referenced in the local sums file.
awk '{print $2}' "$LOCAL_SUMS" | while read -r f; do
  curl -fT "mkosi.output/$f" "$PUSH/"
done

# Merge with whatever's already on dufs, then upload.
{ curl -fsS "$PULL/SHA256SUMS" 2>/dev/null || true; cat "$LOCAL_SUMS"; } \
  | sort -u > /tmp/SHA256SUMS.merged
curl -fT /tmp/SHA256SUMS.merged "$PUSH/SHA256SUMS"

echo "Published"
```

Idempotent: re-running for the same build is a no-op (PUT replaces with
identical bytes; `sort -u` keeps no duplicates).

The only script we ship.

### Pull-side: sysupdate transfer files

Two `*.transfer` files baked into the image, one per artefact, sharing
the same `@v` so sysupdate treats them as one update transaction:

`/usr/lib/sysupdate.d/10-rootfs.transfer`:
```
[Source]
Type=url-tar
Path=https://static.apps.lasath.com/sysupdate/theatre-t480/
MatchPattern=theatre-os_@v.tar.xz
Verify=no

[Target]
Type=subvolume
Path=/sysroot-data/@os/
MatchPattern=@v
ReadOnly=yes
InstancesMax=10
```

`/usr/lib/sysupdate.d/20-uki.transfer`:
```
[Source]
Type=url-file
Path=https://static.apps.lasath.com/sysupdate/theatre-t480/
MatchPattern=theatre-os_@v.efi
Verify=no

[Target]
Type=regular-file
Path=/efi/EFI/Linux/
MatchPattern=theatre-os_@v.efi
InstancesMax=10
```

The path namespaces by host (`theatre-t480/`) even though there's only
one box; cheap insurance in case we ever want a second target later.

`Verify=` defaults to `yes` (require GPG-signed `SHA256SUMS.gpg`).
We set `Verify=no` per source: SHA256 hashes from `SHA256SUMS` are
still checked unconditionally against the downloaded payload (per
`sysupdate.d(5)`), so transport corruption is caught; only the GPG
signature step is skipped — see Architecture → Distribution.

### CI later (not now)

A GitHub Action could run `mkosi build && ./scripts/publish.sh` on
push to `main`. Needs a self-hosted runner (mkosi requires root +
chroots; public runners don't comfortably do this). Skip until
iterating manually becomes annoying.

## Initial install / disk provisioning

Bootstrapping a fresh box. Updates assume the GPT layout, ESP, and
btrfs subvolumes already exist; install creates them from nothing.

### Approach: build a `.raw.xz`, `dd` it to the disk

We build a complete bootable disk image as a **second mkosi
subimage** (sharing the same base config as the release build), then
`dd` it onto the target disk via AMT KVM or a USB rescue env. First
boot, systemd-repart grows the data partition to fill the disk;
otherwise it boots like any other build.

```
# on a rescue env with the target disk visible as /dev/nvme0n1
xzcat theatre-os_<v>.raw.xz | dd of=/dev/nvme0n1 bs=4M status=progress
sync
reboot
```

No live installer, no Calamares, no separate provisioning tool.

### Repo layout

mkosi's subimage mechanism: a top-level `mkosi.conf` for shared
settings, plus `mkosi.images/release/` and `mkosi.images/installer/`
for per-output overrides.

```
mkosi.conf                            # shared base
mkosi.version                         # executable, prints date stamp
mkosi.extra/                          # files overlaid onto the image as-is:
                                      #   custom systemd units (.mount, masks,
                                      #   sleep.d hooks), the theatre-os CLI,
                                      #   /root/.ssh/authorized_keys, etc.
mkosi.images/
  release/
    mkosi.conf                        # Format=tar, SplitArtifacts=uki
  installer/
    mkosi.conf                        # Format=disk, Bootable=yes
    mkosi.repart/
      00-esp.conf
      10-data.conf
```

`mkosi build` produces both subimages by default; `mkosi --image=release build`
or `--image=installer build` builds just one. By default mkosi names
subimage outputs after the subimage rather than the top-level
`ImageId`, so we set `Output=theatre-os` in each subimage's mkosi.conf
to keep names consistent: `theatre-os_<v>.tar.xz`,
`theatre-os_<v>.efi`, `theatre-os_<v>.raw.xz`. (The release and
installer outputs distinguish themselves by extension.)

### Installer disk layout (built by repart)

`mkosi.images/installer/mkosi.repart/00-esp.conf`:
```
[Partition]
Type=esp
Format=vfat
CopyFiles=/efi:/
SizeMinBytes=2G
SizeMaxBytes=2G
```

`mkosi.images/installer/mkosi.repart/10-data.conf`:
```
[Partition]
Type=linux-generic
Label=theatreos-data
Format=btrfs
Subvolumes=/@os/<v>:ro /@persist/seed /@persist/<v>
DefaultSubvolume=/@os/<v>
CopyFiles=<rootfs>:/@os/<v>
CopyFiles=<seed-skeleton>:/@persist/seed
CopyFiles=<seed-skeleton>:/@persist/<v>
SizeMinBytes=4G
GrowFileSystem=yes
```

(Schematic — `<v>` is `&v` in actual config, repart specifier for
ImageVersion. `<rootfs>` and `<seed-skeleton>` are paths produced
during the build by mkosi prep scripts.)

The `seed-skeleton` is a tiny tree of empty mountpoints — empty
`/etc/machine-id`, empty `/etc/ssh/`, empty `/var/log/`, empty
`/home/kodi/.kodi/`, and any other persist bind targets. It exists
solely so the bind-mounts in the boot sequence have somewhere to land
on the very first boot. systemd-firstboot + sshd-keygen populate the
identity files on first boot; Kodi populates `/home/kodi/.kodi` on
first launch; etc.

For initial install, `@persist/seed` and `@persist/<v>` start
identical. Subsequent updates fork new `@persist/<v>` from the
running version's persist (per `theatre-os update`), not from seed.
Seed is only used once, at very-first-boot, ever.

### First-boot grow

The data partition ships at ~4 GiB; the target disk is ~256 GiB+.
`systemd-repart.service` runs early in boot, sees `GrowFileSystem=yes`
in the shipped repart config (also baked into the OS image so it's
available on subsequent boots — irrelevant after the first since
nothing's left to grow). One pass, partition expands to fill the
disk, btrfs grows, done.

### What goes on the dufs server

The installer `.raw.xz` is a one-off-per-host artefact — you only
need a fresh installer when reprovisioning a box from scratch, which
is rare. Three options:

- Upload it alongside releases at install time, delete it after the
  HTPC is up.
- Keep it in `mkosi.output/` on the build host, transfer ad-hoc.
- Upload to dufs under a separate path (`installers/`) for
  occasional reuse.

Default: keep on build host, transfer ad-hoc. Build is reproducible,
can always rebuild if needed. dufs stays focused on update artefacts.

### Recovery via this same image

Useful side effect: the same installer image is also the recovery
tool. If a box's persist subvol gets unrecoverably corrupted, or you
want to start clean, `dd` the installer over again. AMT KVM mounts a
USB rescue env, you `dd`, you reboot. Fifteen minutes from "broken"
to "fresh."

(Persist data is lost. That's acceptable — `/home/kodi/.kodi/` lives
in HA backups via `ha-config`; identity files regenerate; OS state
isn't precious by design.)

## Phased plan

1. mkosi: minimal bootable Arch image in a VM (release subimage only)
2. Add `theatreos-data` btrfs layout (`@os/<v>` + `@persist/<v>`) +
   initrd mount logic in VM
3. Add systemd-sysupdate + `theatre-os update` wrapper in VM
4. Add installer subimage (Format=disk + repart subvols) + verify
   first-boot grow in VM
5. Port LibreELEC tweaks (BT/WOL/power-key/wake-chime) → systemd units
   in image
6. Bring up on T480 via AMT KVM + `dd` of installer image. Stage at
   `theatre-t480.home.lasath.com`, ZBook stays prod at `theatre`.
7. Daily-drive on T480 in parallel with ZBook for 2 weeks; iterate.
8. Cutover: rename T480 to `theatre.home.lasath.com`, point HA's
   Kodi integration at the T480 IP, update the WOL MAC in HA's
   `theatre_turn_on` script. Unplug the ZBook from the AV setup.

## Future work

- **Boot-health telemetry.** Once a few versions are deployed, it would
  be useful to glance at "which versions booted cleanly and which had
  services crashing, and which services". Probably a small post-boot
  script that snapshots `systemctl --failed` and the journal's error
  count per boot, exports it somewhere queryable (HA? a flat file in
  persist? push to a small dashboard?). Cheap to build, big win for
  triaging "did that update I pushed actually work?" without SSHing in.
  Punt until we have enough boot history to want it.
- **Auto-rollback on boot failure** via `systemd-bless-boot` (the
  same mechanism KDE Linux uses). Free, upstream-blessed, ties into
  systemd-boot's boot-counting. Skipped for now — manual rollback via
  the systemd-boot menu is fine while there's only one HTPC and the
  human paying attention is the same one who pushed the update.

## Rejected alternatives

- **Stay on LibreELEC**: moonlight-qt addon couldn't get HW decode on
  Generic; Legacy build = X11 = rotting
- **Bazzite / Silverblue / Kinoite**: bundled DE bloat, designed for
  desktop use, fighting the grain for Kodi-as-shell
- **Arch + Ansible + overlayroot**: simpler, but loses true image
  reproducibility and atomic OS rollback
- **NixOS**: too unfamiliar; AI-generated Nix is hard to review safely

(See "Why this layout" under Architecture for rejected boot/storage
designs: A/B partitions, GRUB+grub-btrfs, erofs files, kernel-in-snapshot.)

## Secrets

AMT password and similar live in `ha-config/secrets.yaml` (gitignored,
included in HA backups).
