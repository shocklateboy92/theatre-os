# Lenovo ThinkPad T480 — Hardware Quirks

Only captures non-obvious / hard-to-rediscover things. For machine
identity (CPU, BIOS rev, etc.), `ssh root@theatre-t480.home.lasath.com`
and use `/proc/cpuinfo`, `dmidecode`, etc. For AMT firmware version,
see the `Server:` header from
`curl -sI http://theatre-t480.home.lasath.com:16992/`.

## Intel AMT (Out-of-Band Management)

vPro/AMT is provisioned. Used for HA hard-reset, KVM-over-IP recovery,
SOL boot debugging. Day-to-day operator essentials (credentials, web
UI URL, SOL command, MAC-sharing DNS quirk, curl power-on snippet)
live in `AGENTS.md` — this file is for deeper provisioning notes
that are only relevant when re-flashing or re-provisioning AMT.

- **Endpoints**: `:16992` web UI / WS-Man, `:16994` SOL/KVM/IDER
  (non-TLS; TLS not configured)

### Quirk: `ListenerEnabled=false` after fresh provision

After enabling SOL/IDER/KVM in MEBx + Activate Network Access, port
16994 is **still refused**. MEBx defines capability; a separate runtime
flag `AMT_RedirectionService.ListenerEnabled` controls the actual
listener bind. Symptom: 16992 responds, 16994 refuses, `amtterm` errors
with "Connection refused".

Fix: PUT the resource with `ListenerEnabled=true` via WS-Man (curl with
`--digest -u admin:$pw`, SOAP envelope wrapping
`http://intel.com/wbem/wscim/1/amt-schema/1/AMT_RedirectionService`,
`<r:ListenerEnabled>true</r:ListenerEnabled>`). Setting persists across
reboots; only need to redo if AMT is fully unprovisioned.

### MEBx setting choices (non-default ones)

Most defaults are fine. The choices that matter and aren't obvious:

- **User Consent for KVM**: NONE (headless appliance, no on-screen
  prompt to approve KVM sessions — defeats the point otherwise)
- **Dynamic DNS Update**: Disabled (UDM Pro doesn't accept RFC 2136)
- **Activate Network Access**: must be done at end (flips Pre- to
  Post-Provisioned)
- **Network Name (hostname)**: set to `theatre-t480` (matches the OS
  hostname). Why: AMT and the host OS share a MAC address but advertise
  separate DHCP client IDs, so they get separate IPs. If they advertise
  *different* hostnames, DNS for `theatre-t480` flaps depending on which
  client renewed its lease last. Matching the hostname makes DNS resolve
  to whichever one is up — OS when running, AMT when the OS is off.
  See `AGENTS.md` for the full explanation.

## BIOS Limitation

No console redirection option in BIOS. POST and the bootloader menu are
**not visible over SOL**, only kernel-and-later. For pre-kernel
debugging, use AMT KVM-over-IP (sees the framebuffer directly).

## Display

HDMI port is 1.4 → caps at 4K@30 / 1080p@60. For 4K@60 use the USB-C
port via DP-alt-mode (the DP-to-HDMI adapter currently on the ZBook
works). USB-C is free for display because charging is via barrel
connector.

The i915 driver fails to drive the external display when the laptop's
internal eDP panel is also enabled (DRM atomic commit fails with
"Invalid argument"). Boot with `video=eDP-1:d` to disable the internal
panel — already baked into the OS image's `KernelCommandLine` in
`mkosi.conf`.
