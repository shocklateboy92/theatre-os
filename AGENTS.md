# theatre-os

Image-based OS for the home theatre HTPC. See `README.md` for design.

## Scope

This repo builds and ships the OS image. It does NOT contain:
- Kodi addons / userdata (lives in `ha-config/kodi/`)
- HA automations or device integrations (lives in `ha-config`)
- Per-machine secrets (lives in `ha-config/secrets.yaml`)

## Target hardware

- T480 staging/prod: `ssh root@theatre-t480.home.lasath.com`
- ZBook (eventual cutover): `ssh root@theatre.home.lasath.com`
- Both have Intel AMT. T480 quirks: `ha-config/t480-hardware-quirks.md`.
  ZBook tweaks (spec for behaviour to preserve): `ha-config/zbook-libreelec-tweaks.md`.

## AMT (out-of-band management)

Used for hard-reset / KVM recovery when the OS is unresponsive.

- AMT user: `admin`
- AMT password: `theatre_t480_amt_password` in `ha-config/secrets.yaml`
- Web UI: `http://theatre-t480.home.lasath.com:16992/`
- SOL: `AMT_PASSWORD=... amtterm theatre-t480.home.lasath.com`

## Build / deploy commands

To be filled in during phase 1.

## Conventions

- All OS state that must survive a reboot lives in the persist
  partition. If you discover a path that needs persistence, add it to
  the list in README and to the mkosi config.
- Don't commit anything that wouldn't survive a wipe-and-rebuild from
  this repo + secrets. The point is reproducibility.
