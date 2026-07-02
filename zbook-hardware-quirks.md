# HP ZBook (bedroom TV) — Hardware Quirks

Status: **first hardware boot done 2026-07-02** (display + audio
characterised; CEC pending the adapter). This box is the `zbook` mkosi
profile (hostname `bedroom-tv`). It shares the theatre-os image with the
T480; only genuinely per-box bits live in `mkosi.profiles/zbook/`. See
README → "Profiles (per-machine targets)".

Silicon: Intel **Comet Lake** — UHD Graphics iGPU (`8086:9bca`, `i915`)
and On-Package HD Audio (`8086:02c8`); HP subsystem `103c:8724`.

For machine identity (exact ZBook model, CPU, GPU, BIOS rev), `ssh
root@bedroom-tv.home.lasath.com` and use `/proc/cpuinfo`, `dmidecode`,
`lspci`, etc. `legacy-zbook-libreelec.md` is the behaviour spec from the
LibreELEC era (WOL-via-dock, BT wake, BLE watchdog, wake chime) — kept
as a reference for features that may need re-implementing.

## Volume: HDMI-CEC via Pulse-Eight USB-CEC adapter

Unlike the T480 (which drives a Denon AVR over the network via a Kodi
addon), the bedroom box has no AVR. Volume is handled over HDMI-CEC
through a Pulse-Eight USB-CEC adapter plugged into the ZBook.

- `kodi` already depends on `libcec`, so no extra package is needed.
  Kodi's built-in **Peripherals → CEC Adapter** driver enumerates the
  Pulse-Eight device and maps volume up/down/mute to the TV (or a
  CEC-capable soundbar) automatically.
- Consequently the `zbook` profile ships **none** of the T480's AVR
  volume addon (`service.avr.volume`), its `zz_avr_volume.xml` keymap,
  or the `theatre-os-avr-logger.service`.
- The adapter presents as a USB CDC-ACM serial device
  (`/dev/ttyACM*`). If Kodi doesn't pick it up, verify the node exists
  and that the `cec-*` peripheral is enabled in Kodi's settings; CEC
  must also be enabled on the TV (vendor names vary: Anynet+, Bravia
  Sync, SimpLink, VIERA Link, etc.).

## Display: blank the internal panel

The `zbook` profile sets `video=eDP-1:d` on the kernel command line
(`mkosi.profiles/zbook/mkosi.conf`). This is **required**, not optional:
Kodi runs gbm-direct on a single CRTC, and if the internal laptop panel
is live Kodi drives it and **nothing reaches the TV**. Blanking eDP-1
forces the external output.

**Confirmed on hardware (2026-07-02):** the internal panel *is* `eDP-1`,
and the TV lands on **`DP-3`** (a DisplayPort output). With eDP-1
blanked, `DP-3` is the only connected connector and Kodi drives it:

```
$ for c in /sys/class/drm/card*-*; do printf '%s %s\n' "$(basename $c)" "$(cat $c/status)"; done
card1-DP-3       connected      # ← the TV
card1-eDP-1      disconnected   # ← internal panel, blanked by video=eDP-1:d
# (all other DP-*/HDMI-A-* disconnected)
```

## Audio: force legacy HDA (SOF firmware not shipped)

**Confirmed on hardware (2026-07-02):** out of the box the ZBook had
**no sound cards at all** (`/proc/asound/cards` → "no soundcards"),
including the iGPU's DP/HDMI audio. Cause: Comet Lake's HD-Audio
controller (`00:1f.3`) defaults to the **SOF** DSP driver
(`sof-audio-pci-intel-cnl`), whose firmware/topology we don't ship:

```
sof-audio-pci-intel-cnl 0000:00:1f.3: SOF firmware and/or topology file not found.
  Firmware file: intel/sof/sof-cml.ri
  Check if you have 'sof-firmware' package installed.
  error: sof_probe_work failed err: -2
```

Fix (in the profile's `KernelCommandLine`):
`snd_intel_dspcfg.dsp_driver=1` forces the legacy `snd-hda-intel`
driver instead of SOF. That produces the same **`PCH`** HDA card the
T480 uses, so the shared `/etc/asound.conf` (`hw:CARD=PCH,DEV=3`) and
Kodi's passthrough device work unchanged — no per-box ALSA config, no
`sof-firmware` package.

Alternative if legacy HDA ever misbehaves: ship the `sof-firmware`
package instead and re-tune `asound.conf`/Kodi for the SOF card name
(`sofhdadsp*`). Legacy HDA is preferred here purely for parity with the
T480's existing, known-good audio config.

After reflashing, verify: `cat /proc/asound/cards` shows a `PCH` card,
`aplay -l` lists its HDMI/DP devices, and audio reaches the TV. If the
DP-3 pipe's audio isn't on `DEV=3`, note the correct `DEV` and adjust
`asound.conf` (shared) or Kodi's device — but the T480 uses `DEV=3` and
it's the usual first display-audio PCM.

## Still open

- **Battery charge threshold.** Confirmed on hardware: `BAT0` exposes
  **no** `charge_control_{start,end}_threshold` sysfs, so the ThinkPad
  40–60% rule can't apply (it's correctly t480-only). Low priority for
  an always-plugged-in box; would need an HP-specific method if wanted.
- **CEC volume.** Pending the Pulse-Eight USB-CEC adapter (not yet
  plugged in — no `/dev/ttyACM*`, nothing in `lsusb`). Once connected,
  enable the `cec-*` peripheral in Kodi and CEC on the TV (Anynet+ /
  Bravia Sync / SimpLink / VIERA Link). See "Volume" above.
- **Audio DEV mapping.** Sanity-check that DP-3's audio is on
  `hw:CARD=PCH,DEV=3` after the legacy-HDA switch (see Audio above).
- **initrd kernel modules.** Root mounted fine in testing; revisit only
  if a future storage/GPU change needs extra early modules.
- **Wake / power.** No AMT on this box. Whatever wake path it uses (WOL,
  CEC power, HA) is TBD — see `legacy-zbook-libreelec.md` for the old
  LibreELEC behaviour.
