# theatre-os

Declarative, image-based OS for the home theatre HTPC. Replaces
LibreELEC with a modern, reproducible build. Kodi is the shell;
moonlight-qt launches from within Kodi for game streaming.

## Architecture

- **Build**: [`mkosi`](https://mkosi.systemd.io/) produces an Arch-based
  root tree from declarative config in this repo. Build output per
  release: `theatre-os_<v>.tar` (root tree) + `theatre-os_<v>.efi`
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
  two entries: the `.tar` is extracted (`Type=url-tar`) into a fresh
  btrfs subvolume on the rootfs partition (`Type=subvolume`); the `.efi`
  UKI is dropped into `/efi/EFI/Linux/` (`Type=regular-file`).
  systemd-boot enumerates UKIs → boot menu shows every installed
  version. Rollback: pick an older entry. Old subvolumes + UKIs are
  GC'd by sysupdate retention policy (keep N).
- **Runtime**: RO `@os/<v>` btrfs subvolume mounted directly at `/` —
  no overlayfs. Writes to `/usr` and most of `/etc` fail loudly,
  enforcing the discipline that config changes must be promoted to
  the mkosi config. The data partition is mounted RW at
  `/system/data` (sysupdate creates new subvolumes there at update
  time); `/var`, `/home/kodi`, and a few `/etc` identity files are
  bind-mounted from a per-version persist subvolume (`@persist/<v>`).
  The ESP is mounted RW at `/efi` so `bootctl`, `kernel-install`, and
  sysupdate's UKI transfer can write to it. Experiments use a separate
  boot mode that snapshots `@os/<v>` and `@persist/<v>` to writable
  throwaway subvolumes — see "Updates & experiment mode".
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
  sysupdate dropping the snapshot and the UKI in one transaction —
  same build, same `@v`, paired by sysupdate's transfer manifest.
  Putting the kernel physically inside the snapshot would require
  GRUB to read it out (the only thing systemd-boot can't do). Not
  worth the complexity.
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
`theatre-t480.home.lasath.com`, post-cutover takes over `theatre.home.lasath.com`
from the existing LibreELEC ZBook). Has Intel vPro / AMT for OOB
recovery — see `t480-hardware-quirks.md`.

The previous production box (HP ZBook Firefly 14 G7 running LibreELEC)
was unplugged from the AV setup at the T480 cutover. theatre-os is
**not** intended to run on it. `legacy-zbook-libreelec.md` is kept as
a reference for the *behaviours* (BT wake, WOL, power-key handling,
wake chime, sleep mode, Shield Remote "find") that worked on the
ZBook and may need to be reimplemented on theatre-os if equivalent
hardware/features come back. Most of the *implementation* tweaks in
that doc are dock/USB-NIC specific to the ZBook and won't port
directly.

## Iteration loop

1. SSH into the box. By default `/` is RO — `pacman -S` and `/etc` edits
   fail loudly. This is correct: writes here aren't supposed to be
   ephemerally easy.
2. `theatre-os experiment` to enter experiment mode live (no reboot;
   btrfs swap-snapshot trick). Now `pacman -S` / `/etc` edits work
   and land in throwaway subvols.
3. Reboot to leave experiment mode → all experimental writes vanish
   (next boot mounts the fresh `@os/<v>` and `@persist/<v>` snapshots
   we created when entering experiment mode).
4. Promote working changes into the mkosi config in this repo
   (`mkosi.conf`, `mkosi.extra/`, `mkosi.images/`, etc.).
5. `./build.sh` → `./publish.sh` → `theatre-os update` on
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
- **`kodi`** — service account for the Kodi process. Defined in
  `mkosi.extra/usr/lib/sysusers.d/kodi.conf` (vendored from the AUR
  `kodi-standalone-service` package; see Custom code summary). Runs
  Kodi (and moonlight-qt invoked from it). Member of `audio video
  input render video_dma optical network`. Pinned to UID/GID **420**
  for stability across rebuilds. No login shell, no SSH. Userdata at
  `/home/kodi/.kodi/` is on the persist subvol via the
  `sysroot-home-kodi.mount` initrd unit.

Out-of-band recovery: Intel AMT (KVM + SOL) on the T480.
See top-level `AGENTS.md` for credentials.

The kernel cmdline includes `console=tty0 console=ttyS0,115200` so
that AMT's Serial-over-LAN sees kernel + systemd output during boot
and any panic. Kodi runs on tty1 and is unaffected. (AMT SOL only
shows kernel onward, not pre-kernel firmware/POST — for those, use
AMT KVM. See `t480-hardware-quirks.md`.)

## Versioning

Image version = build datetime, UTC, minute resolution: `2026-05-09-1422`.

- Sorts correctly as a plain string (sysupdate's `@v` matching is
  lexicographic, not version-aware), so newest builds always win.
- No external counter to maintain — the executable `mkosi.version` in
  the repo (a one-line script) just stamps `date -u +%Y-%m-%d-%H%M`
  and mkosi reads its stdout. Practically never collides.
- Human-readable in the systemd-boot menu: you can tell at a glance
  which entry is newer when troubleshooting.
- Git SHA is recorded separately in `/etc/os-release` as the
  spec-blessed `BUILD_ID=` field for source traceability. The version
  itself doesn't embed the SHA because SHAs don't sort meaningfully.

Artifacts use the version as their stem:
`theatre-os_2026-05-09-1422.tar`, `theatre-os_2026-05-09-1422.efi`.

## Partition layout

Single GPT on the internal NVMe, two partitions:

```
Part 1: ESP             2 GiB    vfat    GUID: ESP                   label: ESP
Part 2: data btrfs      rest     btrfs   GUID: Linux generic data    label: theatre-os-data
```

The btrfs partition holds **both** OS and persist subvolumes:

```
/                                            (btrfs partition root, never mounted as /)
├── @os/2026-05-09-1422
├── @os/2026-05-09-1530
├── @os/2026-05-10-0901                       (RO subvols, written by sysupdate Type=subvolume)
├── @persist/2026-05-09-1422
├── @persist/2026-05-09-1530
└── @persist/2026-05-10-0901                  (RW subvols, one per OS version, CoW-shared)
```

One btrfs (vs two separate partitions for OS and persist) keeps free
space flowing freely between them and simplifies the GPT. The blast
radius of fs corruption covers both, but recovery requires AMT KVM +
USB rescue regardless, so the isolation argument is weak.

ESP is oversized at 2 GiB (UKIs are ~100 MB, retention ~10 versions
= ~1 GiB; see Build & publish for the `KernelInitrdModules=default`
override that keeps UKIs in this range). Comfortably within
FAT32/firmware tolerances; the headroom exists so we can experiment
with alternate boot artefacts (recovery UKIs, debug variants,
multi-profile UKIs) in future without re-partitioning. Shrinking
later is annoying.

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
label `theatre-os-data` and a pinned PARTUUID
(`78332b2c-d061-488f-8f21-41f3fa97226a`, hardcoded in
`mkosi.repart.in/10-data.conf.in`); the initrd looks it up by PARTUUID
(via `/dev/disk/by-partuuid/`), mounts it,
then mounts the appropriate `@os/<v>` and `@persist/<v>` subvolumes
based on the version stamped into the UKI's `/usr/lib/os-release`.

(Existing files like `/etc/fstab` aren't used for these mounts — the
initrd and a small systemd-mount unit handle them, so the same image
works on any host whose data partition uses the pinned PARTUUID. The
PARTUUID, not the label, is what makes the mount work — the label is
informational. Reinstalls re-assert the same PARTUUID via
`mkosi.repart.in/10-data.conf.in`.)

The ESP is mounted RW at `/efi` from the rootfs by a static `efi.mount`
unit (`What=/dev/disk/by-label/ESP`). This mount is needed so
`bootctl`, `kernel-install`, and `systemd-sysupdate` (whose UKI
transfer file uses `PathRelativeTo=esp`) can find and write to the
ESP — despite the man pages implying ESP discovery is automatic, in
practice these tools just look for a mounted FAT volume at one of
`/efi`, `/boot`, or `/boot/efi` and bail otherwise. We use an
explicit `.mount` unit rather than `systemd-gpt-auto-generator`
because the generator hangs `initrd-root-fs.target` waiting for a
discoverable root partition we don't have (see the cmdline rationale
in `mkosi.conf` and `rd.systemd.gpt_auto=0`).

## Persistence model

The data partition holds **one persist subvolume per installed OS
version** (`@persist/<v>`), alongside the `@os/<v>` rootfs subvolumes.

`@persist/<v>` is **created at install time of `<v>`**, not at first
boot. On a fresh install, the installer's `systemd-repart` config
creates `@persist/<v>` directly and populates it from a checked-in
skeleton tree (empty identity files, bind-target stubs). On
**update** from a running version `<r>` to a new `<n>`, the
`theatre-os update` wrapper snapshots `@persist/<r>` → `@persist/<n>`
as part of the install transaction (see "Updates & experiment mode").

There is no separate seed subvolume on disk and no skeleton tree
in the repo. The bind-mount target dirs needed inside `@persist/<v>`
(`/var/log/`, `/etc/ssh/`, etc.) are created on first boot by a
`tmpfiles.d` snippet shipped in the rootfs. Subsequent updates fork
from the running persist, never from a skeleton.

Booting `<v>` is therefore a dumb mount: `@persist/<v>` always already
exists. The version stamped into the booted UKI's `/usr/lib/os-release`
(`IMAGE_VERSION`) selects which subvolume to mount.

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

The bind mount happens **in the initrd** (`sysroot-var.mount`,
binding `/sysroot/system/persist/var` → `/sysroot/var`), so it's
already in place at switch-root. After switch-root, the rootfs's
PID 1 sees `/var` as already-mounted and adopts it as a normal
managed mount. This same pattern applies to all our other mounts
(`system-data`, `system-persist`, `etc/machine-id`) — see Boot
sequence.

Per-version persist subvolumes are seeded at install time with the
**same `/var` tree the rootfs ships** (via repart `CopyFiles=/var:
/@persist/<v>/var`). That way, when the bind attaches at boot,
packages find their state under `/var/lib/{dbus,systemd,…}` intact
— same as on a normal install. Without the seed, services on first
boot would see an empty `/var/lib/` and silently re-initialize state,
which has bitten us once already.

Other persist mounts (specific paths outside `/var`):

- `/var/lib/ssh/ssh_host_*` — sshd host keys. Lives under `/var`
  (so persisted automatically) rather than the conventional
  `/etc/ssh/`. We can't bind-mount `/etc/ssh/` from persist
  without hiding the rootfs-shipped `sshd_config`, and we can't
  bind individual files in `/etc/ssh/` cleanly either; redirecting
  `HostKey=` paths to a writable location is simpler. See
  `mkosi.extra/etc/ssh/sshd_config.d/10-theatre-os.conf` and the
  `sshdgenkeys.service` drop-in that overrides Arch's hardcoded
  ExecStart to write keys to the new path.

- `/var/lib/theatre-os/machine-id` — backing file for the
  `/etc/machine-id` bind mount; populated on first boot. See
  Identity files below.

- `/home/kodi/` — entire kodi user home (Kodi userdata in `.kodi/`,
  moonlight-qt pairing/config in `.config/`, the Kodi instance UUID,
  library, watch state). Bind-mounted from `@persist/<v>/home/kodi`
  via `sysroot-home-kodi.mount` in the initrd. Owned by `kodi:kodi`
  (uid/gid 420 — pinned in `sysusers.d/kodi.conf` for stability
  across rebuilds; mode 0755 so root can traverse for HA's
  `deploy.sh` to land Kodi addons). The directory is pre-created at
  install time inside `@persist/<v>` via repart's `MakeDirectories=`,
  and tmpfiles fixes ownership on every boot.

### Identity files

`/etc/machine-id` is **persistent** via a bind mount set up in the
initrd: `sysroot-etc-machine\x2did.mount` binds
`/sysroot/system/persist/var/lib/theatre-os/machine-id` over
`/sysroot/etc/machine-id` before switch-root. By the time PID 1 in
the running rootfs reads `/etc/machine-id`, it sees a populated
value and skips its transient-machine-id setup entirely (per
`machine-id(5)`'s "first boot semantics", a non-empty
`/etc/machine-id` is treated as already-initialized).

We must do the bind in the initrd because PID 1 in the rootfs reads
machine-id during its own initialization, *before* any `.mount`
unit gets a chance to run — a rootfs-side bind would attach too
late. Doing it in the initrd, before switch-root, is the standard
pattern image-based OSes converge on (silverblue, microos, bootc,
particleos all do it this way).

The persist file is initialized on first boot by the small
`theatre-os-machine-id.service` oneshot in the initrd: if
`/sysroot/system/persist/var/lib/theatre-os/machine-id` doesn't
exist yet, it generates a fresh UUID via `systemd-id128 new`. On
subsequent boots the file already exists and the service no-ops
via `ConditionPathExists=`.

The rootfs ships an empty 0-byte `/etc/machine-id` as the
mountpoint stub (the bind mount needs the target file to exist).
This is the canonical pattern recommended by `machine-id(5)` for
read-only image setups.

sshd host keys are generated on first boot by Arch's `sshdgenkeys.
service` (which we override to write to `/var/lib/ssh/`), then live
in persist forever. No initrd machinery needed — sshd doesn't need
its host keys existing *before* it starts, only by the time
multi-user.target is reached.

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
- `/usr/`, `/opt/`, installed packages — part of the RO `@os/<v>`
  rootfs subvolume; not separate subvols.
- `/run`, `/tmp`, `/dev/shm` — standard tmpfs (systemd-managed).

## Updates & experiment mode

Both updates and experiments use the same primitive: **btrfs writable
snapshots of an otherwise-RO source.** No overlayfs anywhere.

The `theatre-os` CLI is the single entry point for all of this:

| Command | What it does |
|---|---|
| `theatre-os update` | Pull the next release: invoke sysupdate, snapshot persist, paired GC. Refuses if in experiment mode. |
| `theatre-os experiment` | Enter experiment mode live (no reboot): swap-snapshot `@os/<v>` and `@persist/<v>`, flip `/` to RW. Reboot to leave. |
| `theatre-os snapshot [name]` | Manually snapshot persist for a checkpoint before risky persist mutations. Refuses if in experiment mode. |
| `theatre-os snapshot list` | Show manual snapshots. |
| `theatre-os snapshot delete <id>` | Drop a manual snapshot. |
| `theatre-os snapshot prune` | Drop snapshots older than 30 days, with confirm. |
| `theatre-os restore <id>` | Stage a snapshot to be the active persist after the next boot (live swap, same trick as experiment mode; reboot to apply). |

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
SSHes in. To leave experiment mode, **reboot**. The next boot mounts
the fresh `@os/<v>` and `@persist/<v>` snapshots we created at
experiment-on time and resumes normal mode; the `-experiment-<unique>`
subvols stay around for forensic browsing (last N kept). We don't
ship a live `experiment-off` because the reverse-swap logic would be
fragile (open files, RW→RO remount, name conflicts) for marginal
benefit over a 30-second reboot.

If you want to keep something from an experiment: edit the mkosi
config in this repo and ship a new image. Same discipline as the
iteration loop.

**Validated.** The `mount -o remount,rw /` on a btrfs subvol whose
`ro` property was just flipped works cleanly on systemd 260 / Linux
7.0. End-to-end validation in qemu (rename → snapshot back → flip RW
→ remount → write to /usr → reboot → land in fresh RO snapshot,
write gone). Old experiment subvols stay around for forensic
browsing; default retention is 10 (CoW makes them cheap on disk),
older auto-GC'd at next experiment-on.

**Subtle property of btrfs subvol mounts** that this design relies
on: subvol mounts are **inode-tracked** (the kernel resolves the
subvol object once at mount time and follows it regardless of path
renames), NOT path-tracked. Renaming `@os/<v>` → `@os/<v>-experiment-<u>`
leaves the live `/` attached to the same subvol object under its new
name; subsequently creating a fresh `@os/<v>` does NOT cause the live
mount to switch to it. Verified empirically with both `subvol=` and
`subvolid=` mount options — neither switches the live view on a
rename + new-create at the original path.

**`theatre-os snapshot` refuses while in experiment mode.** It would
silently capture the wrong subvol: `running_version()` reads
`IMAGE_VERSION` from `/usr/lib/os-release` (baked at build time,
unaware of the experiment-mode rename), so it'd snapshot
`@persist/<v>` (the pristine fresh-for-next-boot subvol) rather than
`@persist/<v>-experiment-<u>` (the one we're actually mutating). The
snapshot would have a misleading name and miss the in-experiment
state — a future `restore` against it would land you on pristine
state, not what you thought you captured. Same refusal pattern as
`update` and `restore`. To checkpoint persist before risky work in
experiment mode, snapshot **before** entering experiment mode. To
keep changes from experiment mode, edit `mkosi.extra/` in the repo
and ship a new image (the iteration loop).

### `theatre-os update`

A small wrapper around `systemd-sysupdate` that handles the persist
snapshot and the experiment-mode guard. Roughly:

```
theatre-os update:
  1. If running in experiment mode (root mount is on
     @os/<v>-experiment-<u>): refuse and exit.
  2. Determine running version <r> from /usr/lib/os-release
     (IMAGE_VERSION; not VERSION_ID — that's a distro field
     and is unset for rolling Arch).
  3. Record the current @os subvol list (in a shell variable) before
     sysupdate runs.
  4. systemd-sysupdate --verify=no update
                                   # downloads new tar+UKI, extracts
                                   # to @os/<n>, drops UKI in ESP, GCs
                                   # old @os per InstancesMax.
                                   # --verify=no skips GPG signature
                                   # check; SHA256 hashes from
                                   # SHA256SUMS are still verified
                                   # unconditionally per sysupdate.d(5).
  5. Diff the @os list before/after to discover the new <n>.
     (Robust to sysupdate's stdout format changes; we don't try to
     parse human-readable progress text.)
  6. btrfs subvolume snapshot @persist/<r> @persist/<n>
  7. GC orphan @persist/<x> where @os/<x> no longer exists
     (sysupdate doesn't know about persist subvols, so we run our
     own paired GC).
  8. Optionally reboot.
```

The experiment-mode guard ensures `@persist/<n>` forks from the
last-known-good persist (the running version's), not from an ephemeral
experiment snapshot that won't exist after the next reboot.

**Five sysupdate units are masked at image build time.** sysupdate
ships both a CLI (`systemd-sysupdate`) and a D-Bus daemon
(`systemd-sysupdated`). The daemon is what tools like Plasma's
Discover, `updatectl`, etc. drive to perform updates. We don't want
that — anything calling the `org.freedesktop.sysupdate1` D-Bus
interface would invoke a sysupdate install directly, bypassing the
`theatre-os update` wrapper and skipping both the experiment-mode
guard and the persist snapshot. So the image masks (symlinks to
`/dev/null`):

- `systemd-sysupdated.service` (the D-Bus daemon)
- `dbus-org.freedesktop.sysupdate1.service` (the dbus alias for it)
- `systemd-sysupdate.timer` (the periodic auto-update mechanism —
  updates happen only when explicitly invoked by `theatre-os update`,
  never on a schedule; an auto-update at 03:00 that breaks the box
  is harder to debug than one the human just pushed)
- `systemd-sysupdate-reboot.service` and `.timer` (the auto-reboot-
  after-update mechanism — same reasoning).

The CLI is the only entry point. (sysupdate has no native pre/post
hooks — see [systemd#35988](https://github.com/systemd/systemd/issues/35988)
— so a wrapper is the only way to compose snapshot logic with
sysupdate.)

**One TPM unit is also masked: `systemd-pcrproduct.service`.** This
service writes a "product ID" measurement into a TPM2 NV index used as
a virtual PCR (NvPCR). The T480's TPM2 chip (Infineon SLB 9670, 2018-
ish firmware) doesn't correctly implement the `NT_EXTEND` mode that
NvPCR depends on — `systemd-tpm2-setup` logs `unable to allocate
NvPCR 'hardware'/'cryptsetup'/'verity': Operation not supported` and
proceeds with `--graceful`, but `systemd-pcrproduct` then tries to
extend the (never-allocated) `hardware` NvPCR and fails hard, dragging
`systemctl is-system-running` to `degraded` for the rest of the boot.
We don't actually use NvPCR for anything (no FDE, no verity, no
measured-boot policy enforcement — see "No encryption" above), so the
service is pure noise. Mask it.

If we eventually move to hardware with a working TPM (e.g. the ZBook
target may have one), revisit — re-enabling is just deleting the
symlink. Lenovo has stopped issuing TPM firmware updates for the T480
generation, so don't expect a fix from that direction.

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
  Live-swap the chosen snapshot into place as the next boot's persist.
  Reboot to actually use it.
```

Restore uses the **same btrfs swap-snapshot trick as experiment mode**
— mounts are inode-tracked, renaming a subvol doesn't disturb the
live mount. From the running system:

1. Rename current `@persist/<v>` → `@persist/<v>-pre-restore-<ts>`
   (the live mount keeps using it under the new name).
2. Snapshot the chosen `@persist/<v>-snap-<id>` → fresh `@persist/<v>`
   (RW, sitting on disk, unmounted).
3. Reboot. Initrd mounts the fresh `@persist/<v>` and you're on the
   restored state. The renamed `@persist/<v>-pre-restore-<ts>` stays
   around as an undo-of-the-undo.

Caveat: between running `theatre-os restore` and rebooting, the live
system is still on the old (renamed) persist. Writes during that
window land in `-pre-restore-<ts>` and won't appear on the restored
state. The CLI prompts to reboot immediately to avoid this.

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

2. **Kernel → initrd.** mkosi-built initrd with **systemd as PID 1**
   (not dracut) — same systemd as the real root, so any
   `.mount`/`.service`/`.target` units we ship work identically in
   both contexts. The initrd is a sibling subimage at
   `mkosi.images/initrd/` (`Include=mkosi-initrd` + an `mkosi.extra/`
   overlay carrying our custom mounts) rather than mkosi's auto-built
   default — the auto-built initrd does NOT inherit the top-level
   `mkosi.extra/`, so we'd otherwise have no way to ship
   `sysroot.mount` etc. into it.

3. **Mount the OS rootfs subvolume.** The initrd's `sysroot.mount`
   unit mounts `@os/<v>` RO at `/sysroot`. The `<v>` is baked into
   the unit at image-build time by `mkosi.images/initrd/mkosi.
   finalize`, which `sed`'s `@VERSION@` → `$IMAGE_VERSION` against
   the staged unit. Each UKI ships with its own version-specific
   `sysroot.mount`, so booting an older UKI from the systemd-boot
   menu mounts the matching `@os/<v>` correctly.

4. **Mount everything else under `/sysroot/`** — all in the initrd,
   before switch-root. Standard image-OS pattern (silverblue,
   microos, particleos all do this).
   - `sysroot-system-data.mount`: data partition root (subvolid=5)
     at `/sysroot/system/data`, **mounted RW** because sysupdate
     creates new `@os/<v>` subvolumes there at update time, and
     `theatre-os update` snapshots `@persist/<r>` → `@persist/<n>`
     beside them. (The individual `@os/<v>` subvols are independently
     RO; per-version isolation comes from the subvol RO flag, not from
     the partition-root mount option.)
   - `sysroot-system-persist.mount`: `@persist/<v>` at
     `/sysroot/system/persist` (also `@VERSION@`-templated)
   - `sysroot-var.mount`: bind `/sysroot/system/persist/var` over
     `/sysroot/var`
   - `sysroot-home-kodi.mount`: bind
     `/sysroot/system/persist/home/kodi` over `/sysroot/home/kodi`
   - `sysroot-etc-machine\x2did.mount`: bind
     `/sysroot/system/persist/var/lib/theatre-os/machine-id` over
     `/sysroot/etc/machine-id`
   - `theatre-os-machine-id.service`: oneshot that runs *between*
     the persist mount and the machine-id bind on first boot, to
     `systemd-id128 new` into the persist file if it doesn't exist.

   All wired into `initrd-fs.target.requires/`. Setting these up in
   the initrd means the rootfs's PID 1 sees them as already-mounted
   from the moment it starts — and it reads `/etc/machine-id` very
   early in its own initialization, before any rootfs `.mount` unit
   could run, so the bind has to happen pre-switch-root for the
   value to be persistent.

5. **switch-root** into `/sysroot`. The kernel mounts set up under
   `/sysroot/...` survive the namespace transition and re-resolve
   as `/system/data`, `/system/persist`, `/var`, `/etc/machine-id`
   in the running rootfs. The rootfs's PID 1 enumerates
   `/proc/self/mountinfo` at startup and synthesizes mount units
   for them on the fly — no rootfs-side `.mount` units needed.

6. **Rootfs-side mounts.** The rootfs's PID 1 brings up
   `efi.mount`, mounting the ESP RW at `/efi` from
   `/dev/disk/by-label/ESP`. This is needed so `bootctl`,
   `kernel-install`, and `systemd-sysupdate` (whose UKI transfer
   uses `PathRelativeTo=esp`) can write to it. Despite the
   `sysupdate.d(5)` claim that `PathRelativeTo=esp` self-locates
   the ESP, in practice these tools just look for it mounted at
   `/efi`, `/boot`, or `/boot/efi` and bail otherwise.

7. **First-boot identity generation.** `sshdgenkeys.service` (Arch's
   wrapper, with our drop-in overriding the path) generates host
   keys into `/var/lib/ssh/`. They land on the persist subvol via
   the inherited `/var` bind, so they survive reboots and
   rollbacks. `/etc/machine-id` is already populated by the time
   anything reads it (per step 4).

8. **Normal systemd boot.** networkd, sshd, bluetoothd, etc.
   `gpt_auto=0` is on the kernel cmdline to disable
   `systemd-gpt-auto-generator`, which would otherwise leak a
   dependency on `/dev/gpt-auto-root` and hang `initrd-root-fs.
   target` waiting for a discoverable root partition we don't have.
   Side effect: the ESP isn't auto-mounted by the generator either,
   which is why we ship the explicit `efi.mount` (step 6).

9. **Kodi starts.** `kodi-gbm.service` (vendored from the AUR
   `kodi-standalone-service` package — see Custom code summary
   for why we ship it ourselves) launches Kodi as user `kodi`
   against `/dev/dri/card0` via gbm/EGL/KMS, on tty1. The unit
   uses `PAMName=login` to land in `user-N.slice` (so XDG_RUNTIME_DIR,
   the session bus, and tty ownership are set up properly), with
   `Conflicts=getty@tty1.service` so systemd automatically stops
   the getty when Kodi starts (same pattern sddm uses). The unit
   is wired in via `Alias=display-manager.service`, which is
   pulled by `graphical.target` (our `default.target`).
   No gettys run on any other tty either: the kernel cmdline
   carries `systemd.getty_auto=0` to disable autovt spawning
   entirely. Ctrl-Alt-Fn VT switching doesn't work on this
   console anyway, so the gettys would never be reachable from
   the keyboard. Emergency console is AMT SOL on ttyS0. See
   "Kodi & moonlight session" below.

### Custom code summary

Initrd subimage (`mkosi.images/initrd/`):
- The version-templated `sysroot.mount`, the five `sysroot-*` mount
  units (system-data, system-persist, var, home-kodi, etc-machine\x2did)
  and the `theatre-os-machine-id.service` oneshot.
- Per-image `mkosi.finalize` doing `@VERSION@` substitution.

Rootfs (`mkosi.extra/`):
- An empty 0-byte `/etc/machine-id` mountpoint stub.
- `efi.mount` + `local-fs.target.wants/efi.mount` symlink, mounting
  the ESP at `/efi` for sysupdate / bootctl / kernel-install.
- `sshd_config.d/10-theatre-os.conf` redirecting `HostKey=` to
  `/var/lib/ssh/`.
- `sshdgenkeys.service.d/10-theatre-os-persist.conf` overriding
  Arch's hardcoded keygen path to match.
- A symlink wanting sshd from `multi-user.target`.
- The `theatre-os` CLI: dispatcher at `/usr/bin/theatre-os` plus
  `lib.sh` and `cmd-{update,snapshot,restore,experiment}.sh` under
  `/usr/lib/theatre-os/` (one file per verb).
- Sysupdate transfer files at `/usr/lib/sysupdate.d/`:
  `10-rootfs.transfer` (`Type=url-tar` → `@os/<v>` subvol) and
  `20-uki.transfer` (`Type=url-file` → ESP `/EFI/Linux/`).
- Five symlinks to `/dev/null` masking sysupdate's daemon, dbus
  alias, periodic timer, and reboot service+timer (so the
  `theatre-os update` wrapper is the only entry point).
- `kodi-gbm.service` + `display-manager.service` alias symlink +
  `default.target` → `graphical.target` symlink, vendored from the
  AUR `kodi-standalone-service` package (which we don't depend on
  directly because it's AUR-only and we'd rather not stand up AUR
  build infra for a ~25-line unit). Pairs with:
- `sysusers.d/kodi.conf` defining the `kodi` user with pinned UID/GID
  420 and home `/home/kodi` (overriding upstream's `/var/lib/kodi`).
- `tmpfiles.d/kodi.conf` ensuring `/home/kodi` is `0755 kodi:kodi`
  on every boot (the bind-mount target inside `@persist/<v>` is
  pre-created by repart but with no ownership guarantees).
- `usr/lib/systemd/system/theatre-os-moonlight.service`: starts
  moonlight as the kodi user with the same logind-session shape
  as kodi-gbm (PAMName=login, TTYPath=/dev/tty1) so it gets seat-
  delegated DRM access. `Conflicts=kodi-gbm.service` makes start
  auto-stop Kodi; `ExecStopPost=+systemctl --no-block start
  kodi-gbm.service` brings Kodi back when moonlight exits. See
  README → Display ownership.
- `etc/polkit-1/rules.d/10-theatre-os-moonlight.rules`: lets the
  kodi user `systemctl start theatre-os-moonlight.service` without
  auth, so the Kodi launcher addon (in ha-config/kodi/) can fire it.
  Scoped narrowly to that one user + that one unit + the
  manage-units action.
- `etc/asound.conf`: routes ALSA `default` PCM through `dmix` to
  the HDMI/AVR sink so Kodi nav sounds can mix with main playback
  and so moonlight (which opens `default` and has no UI for picking
  a device) reaches HDMI. Kodi's bitstream passthrough opens the
  hw device explicitly and bypasses dmix entirely. See
  README → Audio.
- Kodi vendor addons at `usr/share/kodi/addons/`: `service.avr.volume`,
  `script.theatre.lights.toggle`, `plugin.video.watchlist`,
  `context.go.to.show`, `repository.jellyfin.kodi`, `script.module.yaml`,
  `script.module.iso8601`. Read by Kodi as
  system addons; no SQLite registration required.
- Kodi system keymaps at `usr/share/kodi/system/keymaps/`:
  `zz_avr_volume.xml`, `no_chapter_skip.xml`, `theatre_credits_lights.xml`.
  Loaded before userdata keymaps; userdata can still override per-key.
  The `zz_` prefix on the AVR keymap forces it to load *after* Kodi's
  built-in `keyboard.xml` and `remote.xml` so its `<volume_up>` /
  `<volume_down>` / `<volume_mute>` overrides win — Kodi processes
  system keymaps in alphabetical order with later files overriding
  earlier ones, and the built-ins re-bind the same keys to Kodi's
  internal `VolumeUp`/`VolumeDown`/`Mute` actions.

Top-level `mkosi.finalize` creates the `/system/data`,
`/system/persist`, `/efi`, and `/home/kodi` mountpoint stubs in the
rootfs's `$BUILDROOT` (mkosi.extra would have shipped them, but
git can't track empty dirs).

Top-level `mkosi.conf` sets `UnifiedKernelImageFormat=%i_%v` so the
install-time UKI is named `theatre-os_<v>.efi` to match what
sysupdate writes for update-time UKIs (mkosi's default `&e-&k`
would name it after the kernel and leave it as an orphan that
sysupdate's `InstancesMax` retention can't see — same approach
particleos uses).

Plus the partition layout in `mkosi.repart.in/10-data.conf.in`
(declares subvolumes, pre-creates persist target dirs via
`MakeDirectories=`, seeds `@persist/<v>/var` from rootfs `/var`).

Plus the host-side scripts: `build.sh` (renders repart templates +
invokes mkosi), `publish.sh` (uploads `.tar` + `.efi` +
`SHA256SUMS` to dufs), `vacuum.sh` (deletes all but the last N
versions from dufs).

No generators, no overlayfs, no exotic machinery; total LoC small.

## Kodi & moonlight session

Kodi is the shell. moonlight-qt is launched from inside Kodi for game
streaming and gives the display fully back to Kodi when the user quits
moonlight. Both run compositor-free (gbm/EGLFS direct to KMS) so
refresh-rate and HDR switching work, matching LibreELEC's behaviour.

### Display ownership: stop-and-start handoff

Only one process at a time can hold DRM master on the GPU
(`/dev/dri/card1` on the T480), which means Kodi-gbm and moonlight
cannot share the screen. The original LibreELEC pattern was to use
VT switching: X11 on tty7 would chvt away, releasing DRM master,
and the new app on tty2 would grab it. **That doesn't work with
Kodi-gbm.** Kodi grabs DRM master via the legacy ioctl path and
does NOT relinquish it on VT switch. (Confirmed by Kodi upstream:
*"Without kodi supporting relinquishing being the master when
launching the app and reacquiring it afterwards then launching
another gui app isn't possible"* — Kodi forum tid 373067.) Validated
on real hardware: with Kodi running on tty1, `chvt 2` + launching
moonlight produced `Could not set DRM mode for screen eDP1
(Permission denied)` on every page flip, because Kodi was still
master.

The handoff that actually works is **stop kodi, run moonlight,
restart kodi**. Stopping `kodi-gbm.service` close()'s its DRM fd,
the kernel revokes master, moonlight (running as a fresh process
in its own logind session) grabs it cleanly. When moonlight exits,
kodi-gbm starts back up.

Mechanics:

- Kodi runs on tty1 as `kodi-gbm.service`. Holds DRM master
  whenever it's active. Same `User=kodi` + `PAMName=login` setup
  as before.
- moonlight runs as `theatre-os-moonlight.service`, with
  `Conflicts=kodi-gbm.service` (so starting moonlight automatically
  stops Kodi) and the same `User=kodi` + `PAMName=login` +
  `TTYPath=/dev/tty1` so it gets a real logind session with
  seat-delegated `/dev/dri` access. Without the matching session
  setup, moonlight would fail to open the DRM device with
  `Permission denied` even with Kodi stopped — libseat hands devices
  to whoever owns the active session on the seat.
- When moonlight exits (clean quit, SIGINT, crash), an
  `ExecStopPost=+systemctl --no-block start kodi-gbm.service`
  brings Kodi back. The `--no-block` is necessary: without it, the
  start command waits for kodi-gbm to go active, but kodi-gbm can't
  go active until moonlight is fully `inactive`, and moonlight
  can't go inactive until ExecStopPost returns. Classic deadlock.
  `--no-block` queues the start and returns immediately. The `+`
  prefix runs the command as root (User=kodi can't manage system
  units).
- The kodi user can `systemctl start theatre-os-moonlight.service`
  without auth via a polkit rule scoped to that one unit + that
  one user — see Custom code summary.

Cost: ~5 seconds of black screen on each transition while Kodi
tears down or comes back up. Acceptable for a handoff that happens
once per gaming session, not per-frame. LibreELEC's retroarch
addon uses the same stop-and-start pattern for the same reason.

Trade-off rejected: keeping Kodi running and overlaying moonlight
via a Wayland compositor (cage, gamescope) would skip the visible
gap, but requires switching Kodi to wayland windowing — which
breaks our gbm-direct refresh-rate switching, and the lossless
audio passthrough story leans on ALSA-direct (see Audio below).
Not worth it.

Trade-off rejected: switching Kodi to X11. X-on-tty7 does
relinquish DRM master cleanly on VT switch. But Kodi-x11 loses
HDR / 10-bit passthrough on Linux's open driver stack, which is
why LibreELEC's Generic build moved to GBM in the first place.

### Launcher

There is no launcher script. Triggering moonlight is just
`systemctl start theatre-os-moonlight.service` — the `Conflicts=`
+ `ExecStopPost=` machinery on the unit (see "Display ownership"
above) handles the rest of the lifecycle.

The Kodi addon (lives in the `ha-config/kodi/` repo, *not* this
one — userdata is HA-config scope, not OS-image scope) is a thin
`subprocess.Popen(["systemctl", "start",
"theatre-os-moonlight.service"])` wrapped in whatever menu/button
binding feels right. The polkit rule at
`mkosi.extra/etc/polkit-1/rules.d/10-theatre-os-moonlight.rules`
allows the `kodi` user to start that one specific unit without auth.

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
  (`hdmi:CARD=PCH,DEV=0` on the T480), passthrough device set to the
  same path. This means **Kodi's passthrough output goes straight to
  the hw device** and is unaffected by anything we do to the ALSA
  `default` PCM. That's load-bearing — see the asound.conf below.
- moonlight-qt: opens ALSA via SDL3 (not Qt Multimedia — moonlight's
  audio path is SDL, so `QT_MEDIA_BACKEND=alsa` is a no-op here, and
  setting it was a red herring during initial testing). moonlight-qt
  has no UI for picking a device and just opens ALSA `default`,
  which is why we need an `asound.conf` to route `default` to the
  HDMI sink.

`/etc/asound.conf` (shipped at `mkosi.extra/etc/asound.conf`)
routes `default` → `dmix` → `hw:1,3` (HDMI/AVR). dmix not `hw`,
because Kodi opens `default` for **multiple concurrent streams** —
main playback AND nav-sound effects — and `type hw` is exclusive
single-stream (a second open returns EBUSY and nav sounds stay
silent). dmix mixes streams in software before handing them to the
underlying hw device.

The dmix slave is pinned to 48k/S16/stereo. That's fine for nav
sounds and Wolf's Opus output (moonlight stream audio). Anything
that needs more — multichannel PCM, higher rates, bitstream
passthrough — must address the hw device directly. Kodi's
passthrough already does (per the explicit
`audiooutput.passthroughdevice` setting above), so dmix never
touches a TrueHD/DTS-HD bitstream. Verified: Dolby Digital
passthrough still lights up the AVR's DD indicator with this
config in place.

Card index `1` rather than name `PCH` because ALSA name resolution
(`snd_func_card_inum`) needs read access to the controlC1 control
device, which logind grants via ACL only to processes in the active
seat session. Index works for any process with `/dev/snd` read
access, simplifying debugging from non-seat shells. Card index is
stable on this hardware (the only other card is USB at index 0).

Two related must-haves on `theatre-os-moonlight.service`:

- `Environment=SDL_AUDIO_DRIVER=alsa`. Without this, SDL probes
  PipeWire first; PipeWire is intentionally absent (per the
  philosophy above), so the probe fails. SDL falls back to ALSA,
  but the libpipewire client lib leaks a `pw_loop` on every failed
  probe, and moonlight's audio path retries audio-open ~once a
  second when it can't reach the device. After ~50 retries glibc
  trips a heap consistency check and SIGABRTs the AudioDec thread.
  Setting `SDL_AUDIO_DRIVER=alsa` skips the PipeWire probe
  entirely. (Even with the asound.conf above, this env var is
  necessary as defence in depth — anything that breaks the ALSA
  open path would otherwise re-trigger the same crash.)
- `QT_MEDIA_BACKEND=alsa` is **not** set. It looks load-bearing
  but isn't — moonlight's streaming audio path goes through SDL,
  not Qt Multimedia. Earlier versions of this unit set it; removed
  to avoid suggesting it's the relevant lever.

ALSA hardware devices don't support concurrent access at the hw
level, but Kodi and moonlight never run concurrently anyway —
`Conflicts=kodi-gbm.service` on the moonlight unit guarantees the
display-and-audio handoff is sequential. dmix is for *intra-app*
mixing (Kodi main + nav sounds), not for sharing between Kodi and
moonlight.

Trade-off: no Bluetooth audio output (PipeWire is the modern BT audio
stack). Acceptable for a couch-AVR HTPC. If we ever wanted BT headphones,
we'd add PipeWire alongside but Kodi/moonlight would still bypass it.

### Userdata: addons, skin, keymaps, settings

theatre-os ships the custom Kodi addons and keymaps that are tightly
coupled to this HTPC setup. Everything that is specific to the theatre
hardware, reproducible from source, and must survive a wipe-and-rebuild
lives in this repo. Everything that is per-user state, contains secrets,
or belongs to a third-party project lives in `ha-config/` and is pushed
separately.

**Vendored in this repo** (`mkosi.extra/usr/share/kodi/`):

- `addons/service.avr.volume` — background service forwarding volume
  keys to the Denon AVR via Home Assistant.
- `addons/script.theatre.lights.toggle` — toggles kitchen lights via HA;
  bound to the Netflix button in fullscreen video.
- `addons/plugin.video.watchlist` — video plugin that renders an external
  watchlist API as a widget source.
- `addons/context.go.to.show` — "Go to Show" / "Go to Season" context
  menu items for episodes. Also published as a standalone addon at
  [github.com/shocklateboy92/kodi-context-go-to-show](https://github.com/shocklateboy92/kodi-context-go-to-show).
- `addons/repository.jellyfin.kodi` — Jellyfin Kodi repository addon.
- `addons/script.module.yaml`, `addons/script.module.iso8601` — Python
  module addons that HAKA depends on. Vendored as opaque blobs
  (repackaged Kodi addons of upstream PyYAML / iso8601). Bumped only
  if HAKA needs a newer version.
- `system/keymaps/zz_avr_volume.xml` — maps volume keys to AVR volume
  service calls. The `zz_` prefix forces alphabetical load order to
  beat Kodi's built-in `keyboard.xml` / `remote.xml` (which would
  otherwise re-bind the volume keys to Kodi's internal volume).
- `system/keymaps/no_chapter_skip.xml` — disables accidental chapter skip.
- `system/keymaps/theatre_credits_lights.xml` — dims lights on credits
  via HA keymap action.

Kodi reads system keymaps from `/usr/share/kodi/system/keymaps/` before
userdata keymaps, so these are active out of the box. Vendor addons in
`/usr/share/kodi/addons/` are recognised by Kodi as system addons —
no SQLite registration needed.

**Still deployed by `ha-config/kodi/deploy.sh`**:

- **HAKA** (`script.program.homeassistant`) — third-party HA integration
  addon, lives in its own repo at `/config/HAKA`.
- **HAKA `settings.xml`** — contains the HA long-lived access token;
  belongs in secrets/deploy, never in the image.
- **SkinShortcuts menu config** — user-edited via the Kodi UI; treating
  it as image content would fight the user.
- **Library, watch state, skin choice, Kodi instance UUID** — runtime
  state that lives in `~/.kodi/` on the persist subvol.

`deploy.sh` writes to `/home/kodi/.kodi/` (was `/storage/.kodi/` on
LibreELEC); needs path + SSH endpoint update at cutover.

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
- ~~moonlight-qt forced to ALSA backend (Qt may default to
  PulseAudio compat; need to set `QT_MEDIA_BACKEND` or equivalent).~~
  Resolved 2026-05-13: moonlight uses SDL not Qt Multimedia for
  audio; the relevant lever is `SDL_AUDIO_DRIVER=alsa` on the
  unit, plus an `/etc/asound.conf` routing `default` → `dmix` →
  HDMI hw device. See Audio above.
- HDMI device exclusive-access handoff between Kodi and moonlight
  across the VT switch.
- HDR / refresh-rate state restoration when control returns to Kodi
  (moonlight may have changed the mode mid-stream).

## Build & publish

mkosi does almost everything. A small `publish.sh` script and an
executable `mkosi.version` are the only repo-side glue.

### What mkosi produces for us

A single `Format=disk` build with `SplitArtifacts=uki,tar`,
`Checksum=yes`, and `ImageVersion=` set from `mkosi.version`
produces all three artefacts the rest of the system needs in one go:

```
mkosi.output/
  theatre-os_<v>.raw          # bootable disk image (`dd` install media)
  theatre-os_<v>.tar          # rootfs (sysupdate Type=url-tar input)
  theatre-os_<v>.efi          # UKI (sysupdate Type=url-file input)
  theatre-os_<v>.SHA256SUMS   # checksums covering all three
```

The `.tar` and `.efi` are split out of the disk build (rather than
built separately) so the rootfs is composed exactly once. The `.raw`
is used for fresh installs (`dd` to the target disk); the `.tar`
and `.efi` are what `theatre-os update` pulls down on already-
installed boxes via sysupdate. See "Initial install / disk
provisioning" for how the `.raw` gets onto a fresh box and
"Updates & experiment mode" for the upgrade flow.

Notably we **do not** need to:
- Tar the rootfs ourselves (`SplitArtifacts=tar`).
- Run `ukify` separately (`Bootloader=systemd-boot` + `SplitArtifacts=uki`).
- Hash the artefacts (`Checksum=yes`).
- Stamp the version into multiple places (`ImageVersion=` flows into
  the artefact filenames *and* the rootfs's `/usr/lib/os-release`
  *and* the initrd's `/usr/lib/os-release`).

mkosi and sysupdate are designed to compose; we lean on that.

We do set `UnifiedKernelImageFormat=%i_%v` in `mkosi.conf` so the
install-time UKI inside the disk image is named `theatre-os_<v>.efi`
— matching what sysupdate writes for update-time UKIs. Without this
override, mkosi defaults to `&e-&k` (entry-token + kernel version),
which would leave a differently-named UKI in `/efi/EFI/Linux/` after
install that sysupdate's `InstancesMax` retention can't see (it only
manages files matching its `MatchPattern=theatre-os_@v.efi`). Same
trick particleos uses (`UnifiedKernelImageFormat=%i_%v_%a`). We drop
the architecture suffix since theatre-os only targets x86_64.

We also set `KernelInitrdModules=default` to limit which kernel
modules (and their firmware dependencies) end up in the initrd. The
mkosi default — when the setting is unspecified — bundles **every**
kernel module the running kernel exposes and **all** of their
firmware dependencies, ballooning the UKI from ~100 MB to ~440 MB.
The vast majority of that is Wi-Fi / GPU / sound / cellular firmware
we don't need before switch-root. With our `InstancesMax=10`
retention, an unconstrained UKI would use 4.4 GB of ESP space — more
than the 2 GB ESP we provisioned. With `default` we get ~80 MB of
modules-initrd (block devices, filesystems, the bare minimum to
mount `@os/<v>` and switch-root), totalling ~107 MB UKI and ~1 GB
of ESP usage at full retention — comfortably inside our budget.
Same setting particleos uses.

The rootfs tar is uncompressed. It's a few-hundred-MB tree on a gigabit
LAN — wire time is seconds either way. If wire becomes an issue later,
enable HTTP-level gzip on the dufs/static server (transparent to
sysupdate, no artefact rename needed). Skipping artefact-level
compression means: faster mkosi builds, faster install-time decompress,
and we can change transport compression without touching this repo.

### Version stamping

`mkosi.version` is **executable** in this repo:

```sh
#!/bin/sh
exec date -u +%Y-%m-%d-%H%M
```

mkosi runs it on every build and uses stdout as `ImageVersion=`. That
value flows into the artefact filenames *and* `/usr/lib/os-release`'s
`IMAGE_VERSION=` in both the rootfs and the initrd image. (Not
`VERSION_ID=` — that's the distro version field, which Arch leaves
unset because it's rolling.) One source of truth, no external stamping
step.

### Kernel cmdline is generic

The cmdline is the same string in every UKI we build (currently
something like `quiet rw console=tty0 console=ttyS0,115200` —
see Accounts & remote access for the SOL rationale). The version
flows from `mkosi.version` into the artefact filenames *and* into
`/usr/lib/os-release`'s `IMAGE_VERSION=` in both the rootfs and the
initrd image; the initrd reads it from there to pick `@os/<v>` /
`@persist/<v>`. Same pattern as KDE Linux's mount-generator.

### Building

```
./build.sh           # build (default verb)
./build.sh -f vm     # rebuild and boot in qemu
./build.sh shell     # nspawn into the rootfs without booting
```

The wrapper exists because there are some files mkosi can't expand
the build's version stamp into on its own. There are TWO templating
mechanisms in this repo, working at different layers:

1. **`build.sh` + `mkosi.repart.in/*.in`** for systemd-repart configs.
   These are read by mkosi BEFORE `mkosi.finalize` runs, and mkosi
   doesn't preprocess them, so we have to render them in the source
   tree before invoking mkosi. Output dir (`mkosi.repart/`) is
   gitignored.

2. **`mkosi.images/initrd/mkosi.finalize` + literal `@VERSION@`
   in initrd-side `mkosi.extra/` files** for the version-stamped
   initrd mount units (`sysroot.mount`, `sysroot-system-persist.
   mount`, `sysroot-etc-machine\x2did.mount`). No pre-rendering
   needed — `mkosi.finalize` runs in the build sandbox with
   `$BUILDROOT` pointing at the initrd being assembled and
   `$IMAGE_VERSION` exported — it `sed`'s the placeholders in place,
   inside the throwaway sandbox, with no effect on the source tree.

The top-level `mkosi.finalize` exists too but only for creating
empty `/system/data` and `/system/persist` mountpoint stubs in the
rootfs's `$BUILDROOT` (mkosi.extra would have shipped them, but
git can't track empty dirs without leaving marker files in the
final rootfs).

**Always invoke via `build.sh`, never `sudo mkosi` directly** —
running mkosi without the templating step uses stale repart configs
from the last build.

mkosi handles UKI splitting, SHA256SUMS, version stamping, all
internally. `mkosi.output/` accumulates artefacts across builds;
older versions stick around until manually deleted (we may add a
prune step later if it becomes annoying).

### Local testing

`./build.sh -f vm` boots the just-built `.raw` in qemu
(KVM-accelerated where available) — same image bytes, real systemd,
real boot path. `mkosi ssh` connects in once it's up. This is the
primary test harness for everything that doesn't need real GPU /
audio / BT / AMT.

### `publish.sh`

Discovers the version from the local SHA256SUMS file (mkosi just wrote
it; we don't need to ask mkosi.version again). Filters out `.raw` (it's
install-only and stays on the build host — see "Initial install" for
the rationale). PUTs each artefact to its full URL on dufs (not the
directory: dufs returns 404 for `PUT /<dir>/` even though curl supports
that form for other WebDAV servers). MKCOLs the device subdirectory
first, idempotently, in case it doesn't exist yet (dufs's docs claim
parent-dir auto-creation on PUT but in practice it doesn't). Fetches
the existing master SHA256SUMS from dufs (if any), appends our entries,
uploads merged. Order matters: SHA256SUMS last so consumers don't see a
stale checksum file mid-upload.

dufs at `push.apps.lasath.com` is open for PUT inside the LAN trust
boundary; no auth needed (LAN-only DNS, single trust boundary — see
Architecture → Distribution).

```sh
#!/bin/sh
# usage: publish.sh
set -eu
PUSH="https://push.apps.lasath.com/theatre-t480"
PULL="https://static.apps.lasath.com/sysupdate/theatre-t480"

# Local SHA256SUMS lists exactly what mkosi built this run.
LOCAL_SUMS="$(ls mkosi.output/theatre-os_*.SHA256SUMS | tail -n1)"

# Ensure the device subdir exists. Idempotent: 201 on create, 405 if
# already there.
curl -fsS -X MKCOL "$PUSH/" -o /dev/null || true

# Upload artefacts referenced in the local sums file. sha256sum's
# binary-mode output prefixes filenames with `*`; strip it.
awk '{sub(/^\*/, "", $2); print $2}' "$LOCAL_SUMS" | while read -r f; do
  case "$f" in
    *.tar|*.efi)
      curl -fT "mkosi.output/$f" "$PUSH/$f"   # full file URL, not /
      ;;
  esac
done

# Merge with whatever's already on dufs, then upload. Filter out .raw
# from the local sums so the published index matches what's fetchable.
{ curl -fsS "$PULL/SHA256SUMS" 2>/dev/null || true
  grep -E '\.(tar|efi)$' "$LOCAL_SUMS"
} | sort -u > /tmp/SHA256SUMS.merged
curl -fT /tmp/SHA256SUMS.merged "$PUSH/SHA256SUMS"

echo "Published"
```

Idempotent: re-running for the same build is a no-op (PUT replaces with
identical bytes; `sort -u` keeps no duplicates).

### `vacuum.sh`

Trim dufs to keep only the last N versions. Without this, dufs
accumulates artefacts forever; eventually that's annoying. Default
N=20 = 2x the on-box `InstancesMax=10`, so the server keeps history
slightly longer than any one box does (a box that's been off for a
while can still find an intermediate version).

Runs ad-hoc, not as part of every publish — different blast radius.
`publish.sh` is fast and idempotent; `vacuum.sh` is destructive.

Order matters: delete artefacts first, then rewrite SHA256SUMS. If
interrupted between the two, consumers see SHA256SUMS pointing at
deleted files → sysupdate retries cleanly. Reverse order would leave
orphan artefacts referenced by no checksum; harmless but messier.

```sh
#!/bin/sh
# usage: vacuum.sh [N]   (default 20)
set -eu
N="${1:-20}"
PUSH="https://push.apps.lasath.com/theatre-t480"
PULL="https://static.apps.lasath.com/sysupdate/theatre-t480"

versions=$(curl -fsS "$PULL/SHA256SUMS" \
  | awk '{print $2}' \
  | grep -oE 'theatre-os_[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{4}' \
  | sort -u)

to_delete=$(printf '%s\n' "$versions" | head -n "-$N")
keep=$(printf '%s\n' "$versions" | tail -n "$N")
[ -z "$to_delete" ] && { echo "Nothing to vacuum"; exit 0; }

for v in $to_delete; do
  for ext in tar efi; do
    curl -fsS -X DELETE "$PUSH/$v.$ext" || true
  done
done

# Rewrite SHA256SUMS with only the kept entries.
keep_pat=$(printf '%s\n' "$keep" | paste -sd'|' -)
curl -fsS "$PULL/SHA256SUMS" | grep -E "($keep_pat)" > /tmp/SHA256SUMS.vac
curl -fT /tmp/SHA256SUMS.vac "$PUSH/SHA256SUMS"
```

The two scripts (`publish.sh` and `vacuum.sh`) are the only host-side
glue we ship.

### Pull-side: sysupdate transfer files

Two `*.transfer` files baked into the image, one per artefact, sharing
the same `@v` so sysupdate treats them as one update transaction:

`/usr/lib/sysupdate.d/10-rootfs.transfer`:
```
[Source]
Type=url-tar
Path=https://static.apps.lasath.com/sysupdate/theatre-t480/
MatchPattern=theatre-os_@v.tar

[Target]
Type=subvolume
Path=/system/data/@os/
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

[Target]
Type=regular-file
Path=/EFI/Linux/
PathRelativeTo=esp
MatchPattern=theatre-os_@v.efi
InstancesMax=10
```

The `Path=` namespaces by host (`theatre-t480/`) even though there's
only one box; cheap insurance in case we ever want a second target later.

`PathRelativeTo=esp` requires the ESP to be mounted at one of the
canonical paths (`/efi`, `/boot`, `/boot/efi`) — see Boot sequence,
step 6, for the explicit `efi.mount` we ship.

**No `Verify=` directive.** Older sysupdate had a `Verify=no` key for
disabling GPG signature verification. Modern systemd (260+) removed it
from `sysupdate.d` files; the equivalent is the `--verify=no` flag
passed at invocation time, which the `theatre-os update` wrapper
includes. SHA256 hashes from `SHA256SUMS` are still verified
unconditionally regardless of `--verify=` — that's a separate code path
in sysupdate. So transport corruption is caught; only the GPG
signature step is skipped — see Architecture → Distribution.

### CI later (not now)

A GitHub Action could run `./build.sh && ./publish.sh` on
push to `main`. Needs a self-hosted runner (mkosi requires root +
chroots; public runners don't comfortably do this). Skip until
iterating manually becomes annoying.

## Initial install / disk provisioning

Bootstrapping a fresh box. Updates assume the GPT layout, ESP, and
btrfs subvolumes already exist; install creates them from nothing.

### Approach: build a `.raw`, `dd` it to the disk

The `theatre-os_<v>.raw` artefact mkosi produces is a complete
bootable disk image (built as part of the same single-image
`Format=disk` build that produces the sysupdate `.tar` and `.efi`
artefacts — see Build & publish). To install on a fresh box, `dd`
it onto the target disk via AMT KVM or a USB rescue env. First
boot, systemd-repart grows the data partition to fill the disk;
otherwise it boots like any other build.

```
# on a rescue env with the target disk visible as /dev/nvme0n1
dd if=theatre-os_<v>.raw of=/dev/nvme0n1 bs=4M status=progress
sync
reboot
```

No live installer, no Calamares, no separate provisioning tool, no
separate installer subimage — the same `.raw` we test in `mkosi vm`
is the install media.

### Repo layout

```
mkosi.conf                            # all top-level mkosi config
                                      #   (Format=disk, package list,
                                      #   kernel cmdline,
                                      #   UnifiedKernelImageFormat=, etc.)
mkosi.version                         # executable, prints date stamp
mkosi.extra/                          # files overlaid onto the rootfs:
                                      #   sshd config drop-ins, root
                                      #   SSH pubkeys, the empty
                                      #   /etc/machine-id mountpoint
                                      #   stub, sshdgenkeys override,
                                      #   efi.mount + local-fs target
                                      #   wants, sysupdate transfer
                                      #   files, sysupdate /dev/null
                                      #   masks, the theatre-os CLI.
mkosi.finalize                        # creates /system/data,
                                      #   /system/persist, and /efi
                                      #   mountpoint stubs in
                                      #   $BUILDROOT (mkosi.extra
                                      #   can't track empty dirs cleanly).
mkosi.repart.in/                      # repart configs, with @VERSION@
                                      #   placeholders. Source of truth.
  00-esp.conf
  10-data.conf.in
mkosi.repart/                         # generated by build.sh from
                                      #   mkosi.repart.in/. Gitignored.
mkosi.images/initrd/                  # custom initrd subimage —
                                      #   Include=mkosi-initrd plus our
                                      #   own mkosi.extra/ overlay
                                      #   carrying all the .mount units
                                      #   and theatre-os-machine-id.
                                      #   service.
  mkosi.conf
  mkosi.finalize                      # @VERSION@ → $IMAGE_VERSION
                                      #   substitution against the
                                      #   initrd's $BUILDROOT.
  mkosi.extra/...
build.sh                              # build entry point at the repo
                                      #   root (NOT under scripts/) so
                                      #   it's hard to miss — runs the
                                      #   repart templating step then
                                      #   exec's sudo mkosi. Always
                                      #   invoke this instead of mkosi
                                      #   directly.
publish.sh                            # uploads sysupdate artefacts to
                                      #   dufs (the .raw stays local).
vacuum.sh                             # trims dufs to last N versions.
```

The only `mkosi.images/` subimage we need is the custom initrd. The
main bootable disk image (`Format=disk`) lives at the top level so
mkosi's `vm`/`boot`/`shell` verbs work against it directly (those
verbs only operate on the top-level image, not on subimages — see
mkosi 26 source). The `tar` and `.efi` artefacts come out of the
same single build via `SplitArtifacts=uki,tar`.

### Installer disk layout (built by repart)

`mkosi.repart.in/00-esp.conf` (static, copied verbatim):

```
[Partition]
Type=esp
Format=vfat
CopyFiles=/efi:/      # systemd-boot + loader.conf
CopyFiles=/boot:/     # UKI(s) under EFI/Linux/
SizeMinBytes=2G
SizeMaxBytes=2G
```

`mkosi.repart.in/10-data.conf.in` (templated; `@VERSION@` substituted
at build time by `build.sh`):

```
[Partition]
Type=linux-generic
Label=theatre-os-data
UUID=78332b2c-d061-488f-8f21-41f3fa97226a
Format=btrfs
MakeDirectories=/@os /@persist /@os/@VERSION@/var /@persist/@VERSION@/var /@persist/@VERSION@/var/lib /@persist/@VERSION@/var/lib/ssh /@persist/@VERSION@/var/lib/theatre-os /@persist/@VERSION@/home /@persist/@VERSION@/home/kodi
Subvolumes=/@os/@VERSION@:ro /@persist/@VERSION@
CopyFiles=/:/@os/@VERSION@
ExcludeFilesTarget=/@os/@VERSION@/var
CopyFiles=/var:/@persist/@VERSION@/var
SizeMinBytes=8G
GrowFileSystem=yes
```

`@os` and `@persist` are plain directories acting as containers for
the versioned subvolumes (so that sysupdate's `Type=subvolume
Path=/system/data/@os/` can drop `@os/<new-v>` alongside existing
ones). `MakeDirectories=` creates them; `Subvolumes=` creates the
versioned children.

`@persist/<v>` is also pre-populated at install time:
- The empty bind-mount target dirs (`/var/lib/ssh/`,
  `/var/lib/theatre-os/` for the persisted machine-id, …) are
  created by `MakeDirectories=`. Done at install time rather than
  at first boot via tmpfiles because tmpfiles runs
  `After=local-fs.target` and our bind mounts feed INTO that
  target — declaring tmpfiles as a dependency creates an ordering
  cycle that systemd resolves by deleting `local-fs.target/start`
  and dropping the system into emergency.
- `/var/...` is seeded with the rootfs's `/var` tree
  (`CopyFiles=/var:/@persist/<v>/var`) so packages find their
  state under `/var/lib/{dbus,systemd,…}` populated on first
  boot. Without the seed, services silently re-initialize state
  to empty.

`@os/<v>/var/` is left empty — `ExcludeFilesTarget=` keeps the
rootfs's `/var/` contents out of the OS subvolume (they're
bind-shadowed by the inherited `/var` bind mount at runtime
anyway, so duplicating them costs disk for no benefit).
`MakeDirectories=` ensures the empty `/@os/<v>/var/` directory
exists so the bind mount has a mountpoint to attach to (set up
in the initrd at `/sysroot/var` — see Boot sequence).

The version templating exists because systemd-repart's `Subvolumes=`
doesn't expand specifiers — see `repart.d(5)` SPECIFIERS. mkosi
itself has `&v` for ImageVersion in its own configs, but doesn't
preprocess the repart configs it hands to systemd-repart.

### First-boot grow

The data partition ships at ~8 GiB (was 4 GiB pre-Kodi; bumped in
phase 5 to fit the seeded rootfs + Qt stack); the target disk is
~256 GiB+. `systemd-repart.service` runs early in boot, sees
`GrowFileSystem=yes`
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

(Phases 1-4 are validated locally with `mkosi vm` — see Build &
publish → Local testing.)

1. mkosi: minimal bootable Arch image (Format=tar, just to verify
   the build pipeline composes).
2. **(was 4)** Installer is just `Format=disk` on the top-level
   `mkosi.conf` with custom `mkosi.repart/` configs building the
   `theatre-os-data` btrfs layout (`@os/<v>` + `@persist/<v>`).
   Single image build produces the bootable `.raw` *and* the sysupdate
   `.tar` + `.efi` artefacts via `SplitArtifacts=uki,tar`. Disk builds
   but doesn't boot to a real shell yet — no mount logic, drops to
   emergency. This step exists ahead of phase 3 so the rest of the
   work has a real `mkosi vm` test loop instead of a hand-rolled
   fake disk.
3. Add initrd-side mount logic. All filesystem setup happens in the
   initrd before switch-root: `@os/<v>` at `/sysroot`, the data
   partition root at `/sysroot/system/data`, `@persist/<v>` at
   `/sysroot/system/persist`, plus bind mounts for `/sysroot/var`
   and `/sysroot/etc/machine-id`. After switch-root, the rootfs's
   PID 1 inherits these as already-attached mounts. machine-id is
   persistent (from a file under persist that's auto-generated on
   first boot). All custom units live in the `mkosi.images/initrd/`
   subimage; version stamping happens via `mkosi.images/initrd/
   mkosi.finalize`. Disk from step 2 now boots end-to-end in
   `mkosi vm`. Verify first-boot grow at the same time.
4. ✅ Add systemd-sysupdate + `theatre-os update` wrapper, plus
   `publish.sh` (push to dufs) and `vacuum.sh` (trim to last N).
   Validated end-to-end: build A, publish, install in fresh VM,
   build B, publish, `theatre-os update` inside VM, reboot, confirm
   on B; pick A from systemd-boot menu, reboot, confirm rollback;
   run `vacuum.sh 1`, confirm dufs trimmed.
5. ✅ Add Kodi (gbm) + moonlight-qt + the moonlight launcher script.
   `kodi-standalone-service` is AUR-only, so we vendor its
   `kodi-gbm.service` + sysusers + tmpfiles into `mkosi.extra/`
   rather than standing up AUR build infrastructure (revisit if we
   ever build Kodi ourselves to test experimental features). LibreELEC
   tweaks (BT/WOL/power-key/wake-chime) need real hardware to
   validate; deferred to phase 6.
5.5 ✅ Implement the remaining `theatre-os` CLI verbs (snapshot,
   restore, experiment) so we can master experimental mode and
   recovery before touching real hardware. The README's "needs
   prototyping" caveat for the live `mount -o remount,rw /` step in
   experiment mode is now answered: the dance works cleanly. All
   three verbs validated end-to-end in qemu.
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

(See "Why this layout — alternatives we rejected" under Architecture
for rejected boot/storage designs: A/B partitions, GRUB+grub-btrfs,
erofs files, kernel-in-snapshot.)

## Secrets

AMT password and similar live in `ha-config/secrets.yaml` (gitignored,
included in HA backups).
