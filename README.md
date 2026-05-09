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
  instance at `push.apps.lasath.com/theatre-<host>/`, served read-only
  via HTTPS at `static.apps.lasath.com/sysupdate/theatre-<host>/`. LAN-only
  DNS, real Let's Encrypt cert. No GPG signing — single-tenant LAN, the
  build host and image host are inside the same trust boundary;
  HTTPS + SHA256SUMS catches transport corruption and is the realistic
  threat. (Adding signing later is a non-breaking change if needed.)
- **Deploy**: [`systemd-sysupdate`](https://www.freedesktop.org/software/systemd/man/latest/systemd-sysupdate.html)
  on the HTPC pulls each release over HTTPS. The transfer manifest has
  two entries: the `.tar.xz` is extracted (`Type=url-tar`) into a fresh
  btrfs subvolume on the rootfs partition (`Type=subvolume`); the `.efi`
  UKI is dropped into `/boot/EFI/Linux/` (`Type=regular-file`).
  systemd-boot enumerates UKIs → boot menu shows every installed
  version. Rollback = pick an older entry. Old subvolumes + UKIs GC'd
  by sysupdate retention policy (keep N).
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
- KDE Linux — btrfs-snapshot + UKI + systemd-boot model we're copying.

### Why this layout, not the alternatives

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

- **Staging + initial prod**: Lenovo ThinkPad T480 (`192.168.0.78`).
  See `ha-config/t480-hardware-quirks.md`.
- **Eventual**: HP ZBook Firefly 14 G7 (current LibreELEC box).
  See `ha-config/zbook-libreelec-tweaks.md` for the spec of behaviours
  that must work post-rebuild.
- Both have Intel vPro/AMT for OOB recovery.

## Iteration loop

1. SSH into the box. By default `/` is RO — `pacman -S` and `/etc` edits
   fail loudly. This is correct: writes here aren't supposed to be
   ephemerally easy.
2. To experiment: reboot, edit cmdline at the systemd-boot menu,
   add `theatreos.experiment=1`. Now `pacman -S` / `/etc` edits work
   and land in throwaway snapshots.
3. Reboot back to normal mode → all experimental writes vanish.
4. Promote working changes into `mkosi/` config in this repo.
5. `mkosi build` → publish image → `theatre-os update` on the box,
   reboot.
6. Verify; if broken, reboot and pick the previous UKI from the
   systemd-boot menu (or recover via AMT KVM if unbootable).

The forced-forgetting on reboot is a feature: the only way to keep a
fix is to commit it to the repo.

## Accounts & remote access

Two accounts exist on the running system:

- **`root`** — administration. SSH login is the only access path; key
  auth only, password auth disabled. The authorised pubkey lives in
  this repo (`mkosi/pubkeys/root.pub`, public by design) and is baked
  into the RO root at `/root/.ssh/authorized_keys`. Rotating the
  allowed key = edit the file in this repo and ship a new image. There
  is no per-host customisation; one image, one key, all hosts.
- **`kodi`** — service account created by Arch's `kodi-standalone-service`
  package. Runs Kodi (and moonlight-qt invoked from it). Member of
  `audio video input render wheel network`. No login shell, no SSH.
  Userdata at `/home/kodi/.kodi/` is on the persist subvol.

Out-of-band recovery: Intel AMT (KVM + SOL) on both target machines.
See top-level `AGENTS.md` for credentials.

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
Part 1: ESP             1 GiB    vfat    GUID: ESP                   label: ESP
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

ESP is oversized at 1 GiB (UKIs are ~50–100 MB, retention ~10 versions
= <1 GiB). Cheap insurance; shrinking later is annoying.

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
based on the kernel cmdline `theatreos.version=<v>` baked into the UKI.

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
exists. The kernel cmdline `theatreos.version=<v>` baked into the UKI
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
keeps the image artifact non-sensitive and lets one image run on
multiple hosts (T480, ZBook) without identity collisions.

We disable `systemd-coredump` writing coredumps to disk — a
crash-looping service could otherwise fill `/var/lib/systemd/coredump/`
unbounded.

### What's *not* persistent (deliberately)

- `/etc/` (except the few identity files above) — fully baked by mkosi.
  Edits during normal-mode SSH sessions fail loudly (`/` is RO). The
  only way to make a config change stick is to promote it into the
  mkosi config in this repo. KDE Linux makes /etc persistent because
  it's a general-purpose desktop; we're a sealed appliance and the
  forced-forgetting is the whole point of the iteration loop.
- `/usr/`, `/opt/`, installed packages — RO subvolume.
- `/run`, `/tmp`, `/dev/shm` — standard tmpfs (systemd-managed).

## Updates & experiment mode

Both updates and experiments use the same primitive: **btrfs writable
snapshots of an otherwise-RO source.** No overlayfs anywhere.

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

Enabled by editing the kernel cmdline at the systemd-boot menu (press
`e`) and adding `theatreos.experiment=1`. No second UKI to ship; the
discipline cost (a deliberate keystroke) makes experiment-mode
deliberate.

When the flag is set, the initrd:

1. Snapshots `@os/<v>` → `@os/<v>-experiment-<unique>` (writable).
2. Snapshots `@persist/<v>` → `@persist/<v>-experiment-<unique>` (writable).
3. Mounts those snapshots instead of the originals.
4. Sets a motd / journal banner so `ssh` sessions know they're in
   experiment mode.

All writes during this boot — to `/usr`, `/etc`, `/var`, anywhere —
land in the experiment snapshots. Next normal boot reverts everything:
the originals are mounted and the experiment snapshots are retained
for forensic browsing (last N kept, older GC'd).

If you want to keep something from an experiment: edit the mkosi
config in this repo and ship a new image. Same discipline as the
iteration loop in the original design.

### `theatre-os update`

A small wrapper around `systemd-sysupdate` that handles the persist
snapshot and the experiment-mode guard. Roughly:

```
theatre-os update:
  1. If running with theatreos.experiment=1: refuse and exit.
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

## Boot sequence

From power-on to a Kodi prompt. Most steps are stock systemd / mkosi
behaviour; the custom pieces are noted.

1. **Firmware → systemd-boot.** UEFI loads systemd-boot from the ESP,
   which enumerates `EFI/Linux/*.efi` UKIs and presents a menu (or
   auto-selects after timeout). The selected UKI bundles kernel +
   initrd + cmdline, including `theatreos.version=<v>` baked at build
   time. *Free.*

2. **Kernel → initrd.** Standard mkosi-built initrd: drivers, udev,
   systemd in initrd context. *Free.*

3. **Mount the data partition.** Initrd finds `/dev/disk/by-label/theatreos-data`
   via udev and mounts the btrfs root at `/sysroot-data` (or similar).
   *Small custom piece*: a mount unit or generator in the initrd.

4. **Resolve which subvolumes to mount.** Read `theatreos.version=<v>`
   and (optionally) `theatreos.experiment=1` from cmdline.
   - Normal: target subvols are `@os/<v>` and `@persist/<v>`. Both
     pre-existing.
   - Experiment: snapshot `@os/<v>` → `@os/<v>-experiment-<unique>` RW,
     snapshot `@persist/<v>` → `@persist/<v>-experiment-<unique>` RW.
     Target subvols are the snapshots. GC oldest experiment snapshots
     beyond retention N. *Custom oneshot* in initrd.

5. **Mount root and persist.** Mount the OS subvol (RO in normal mode,
   RW in experiment) as `/sysroot`. Mount the persist subvol at
   `/sysroot/run/persist` (or similar). Bind-mount `/sysroot/var` from
   `<persist>/var`, `/sysroot/home/kodi/.kodi` from `<persist>/home-kodi-kodi`,
   `/sysroot/etc/machine-id` from `<persist>/etc-machine-id`, etc.
   *Custom* `.mount` units shipped in the image; mkosi config
   pre-creates the empty mountpoints in the OS tree.

6. **switch-root** into `/sysroot`.

7. **First-boot identity generation.** On a fresh install, the seeded
   persist has empty `/etc/machine-id` and no `/etc/ssh/ssh_host_*`.
   `systemd-firstboot` generates the machine-id; sshd's keygen unit
   generates host keys. Both write to bind-mounted persist paths and
   stick across reboots and OS rollbacks. *Free* (stock systemd) — we
   just need correct ordering (after persist binds, before consumers).

8. **Normal systemd boot.** networkd, sshd, bluetoothd, etc. *Free.*
   In experiment mode, a motd/journal banner advertises the mode.

9. **Kodi starts.** `kodi-standalone-service` (Arch package) launches
   Kodi as user `kodi` against `/dev/dri/card0` via gbm/EGL/KMS. See
   Kodi/moonlight section (TODO).

### Custom code summary

Everything custom lives in (a) the initrd (mount + version-pick +
experiment-snapshot setup) and (b) a handful of `.mount` units shipped
in the image, plus (c) a small `theatre-os update` wrapper. No
overlayfs, no exotic machinery; total LoC expected to be small.

## Phased plan

1. mkosi: minimal bootable Arch image in a VM
2. Add overlayroot (RO + tmpfs + persist partition) in VM
3. Add systemd-sysupdate (N-slot subvolumes + UKI per slot) in VM
4. Port LibreELEC tweaks (BT/WOL/power-key/wake-chime) → systemd units
   in image
5. Bring up on T480; provision AMT KVM access
6. Daily-drive 2 weeks; iterate
7. Cutover ZBook (same image, hardware-specific overrides)

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
