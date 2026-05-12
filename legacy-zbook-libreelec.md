# Legacy: LibreELEC on HP ZBook Firefly 14 G7 — Tweaks

> **Historical reference.** This documents the previous theatre HTPC
> setup: LibreELEC 12 on an HP ZBook Firefly 14 G7. That machine was
> retired and unplugged from the AV stack at the T480 cutover. The
> current production box runs **theatre-os** on a Lenovo T480.
>
> This file is preserved as a *behaviour spec* — if any of the
> features below (WOL via dock, BT wake, BLE reconnect watchdog,
> power-key handling, wake chime, Shield Remote "find") need to be
> reimplemented on theatre-os or a future HTPC, this is the record
> of how they worked and what gotchas they involved. The
> *implementation* details (sysfs paths, USB topology, LibreELEC
> `/storage/.config/` layout) are ZBook/LibreELEC specific and won't
> port directly.

## Hardware

- **Laptop**: HP ZBook Firefly 14 G7 Mobile Workstation
- **OS**: LibreELEC 12.2.1 (Generic.x86_64), kernel 6.16.12
- **Dock**: Lenovo ThinkPad Hybrid USB-C with USB-A Dock
- **Ethernet**: Realtek RTL8153B (USB, via dock) — MAC `00:50:b6:9d:3b:5c`, driver `r8152`
- **Bluetooth**: Intel AX201 (internal USB `1-10`)
- **Remote**: NVIDIA SHIELD Remote (BT HID) — MAC `3C:6D:66:19:95:D0`
- **Sleep mode**: s2idle (not S3 deep) — required for USB-C dock to stay powered

## Battery

- BIOS set to **"Maximize Battery Health"** (caps charge at ~80% of design capacity)
- Battery manufactured June 2020, 102 cycles, 80% health — acts as a built-in UPS
- No Linux-level charge limit needed; the BIOS handles it

## Wake-on-LAN (Ethernet via USB-C Dock)

### Problem

WOL magic packets reached the NIC (dock link LED blinks during sleep) but the
machine wouldn't wake. The NIC's `ethtool wol g` was already set, but the USB
wakeup chain above it was entirely disabled.

### Root cause

Every layer between the NIC and the CPU had wakeup disabled:

| Layer | sysfs path | Default |
|-------|-----------|---------|
| USB NIC | `4-1.3` | enabled |
| USB Hub (dock) | `4-1` | **disabled** |
| USB Root Hub | `usb4` | **disabled** |
| PCI xHCI (Thunderbolt) | `0000:37:00.0` | **disabled** |
| ACPI `TXHC` | Thunderbolt xHCI | **disabled** |
| ACPI `RP05` | PCIe root port | **disabled** |

### Fix

Applied in `/storage/.config/autostart.sh` (runs on every boot):

```bash
ethtool -s eth0 wol g

echo enabled > /sys/bus/usb/devices/4-1.3/power/wakeup
echo enabled > /sys/bus/usb/devices/4-1/power/wakeup
echo enabled > /sys/bus/usb/devices/usb4/power/wakeup
echo enabled > /sys/devices/pci0000:00/0000:00:1c.0/0000:01:00.0/0000:02:02.0/0000:37:00.0/power/wakeup

grep -q "TXHC.*disabled" /proc/acpi/wakeup && echo TXHC > /proc/acpi/wakeup
grep -q "RP05.*disabled" /proc/acpi/wakeup && echo RP05 > /proc/acpi/wakeup
```

### Notes

- The system uses **s2idle** (not S3 deep sleep). This is essential — S3 cuts
  power to Thunderbolt ports entirely, which would kill the dock and make WOL
  impossible.
- `[s2idle] deep` in `/sys/power/mem_sleep` means s2idle is selected (bracketed)
  and deep is available but not used.

## Bluetooth Wake from Suspend (SHIELD Remote)

### Problem

The SHIELD Remote was paired and working, but pressing buttons wouldn't wake
the machine from suspend.

### Root cause (two issues)

1. **USB wakeup chain disabled** — same pattern as WOL. The internal Intel BT
   adapter at USB `1-10` had wakeup disabled at the device, root hub, PCI, and
   ACPI levels.

2. **BlueZ `WakeAllowed` set to `no`** — even with USB wakeup enabled, BlueZ
   blocks wake signals from BT devices unless explicitly allowed. BlueZ resets
   this on every BLE reconnect (which happens after every resume), despite
   persisting `WakeAllowed=true` in the device config file.

### Fix

#### USB/ACPI wakeup (in `autostart.sh`)

```bash
echo enabled > /sys/bus/usb/devices/1-10/power/wakeup
echo enabled > /sys/bus/usb/devices/usb1/power/wakeup
echo enabled > /sys/devices/pci0000:00/0000:00:14.0/power/wakeup
grep -q "XHC .*disabled" /proc/acpi/wakeup && printf "XHC\n" > /proc/acpi/wakeup
```

#### BlueZ WakeAllowed (in `autostart.sh`, delayed for BT to connect)

*(Removed — `bt-monitor.service` now handles WakeAllowed; see below.)*

#### Re-enable USB wakeup after every resume (systemd service)

`/storage/.config/system.d/bt-wake-resume.service`:

```ini
[Unit]
Description=Re-enable BT USB wakeup after resume
After=suspend.target hibernate.target hybrid-sleep.target suspend-then-hibernate.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c "echo enabled > /sys/bus/usb/devices/1-10/power/wakeup 2>/dev/null; echo enabled > /sys/bus/usb/devices/usb1/power/wakeup 2>/dev/null; echo enabled > /sys/devices/pci0000:00/0000:00:14.0/power/wakeup 2>/dev/null"

[Install]
WantedBy=suspend.target hibernate.target hybrid-sleep.target suspend-then-hibernate.target
```

> **Note:** An earlier version of this service also ran `bluetoothctl wake …`
> via pipe, but `bluetoothctl` 5.83 segfaults when used non-interactively after
> resume. The `bt-monitor` service below handles WakeAllowed instead.

### LibreELEC Bluetooth "Enable Standby" setting

This setting is **unrelated to suspend/wake**. It tells LibreELEC to
*disconnect* selected BT devices when the screensaver activates or after an
idle timeout. **Leave it OFF** — enabling it would disconnect the remote and
prevent wake from working.

## BLE Reconnection Watchdog (`bt-monitor`)

### Problem

The Shield Remote is a BLE HID device that disconnects after ~5 minutes of
inactivity and reconnects on the next button press. With BlueZ 5.83 and
kernel 6.16, two bugs conspire to break this:

1. **Kernel LE accept-list failure** — `No such LE device 3c:6d:66:19:95:d0
   (0x0)` is logged on every adapter power-on. The kernel fails to add the
   remote to the LE accept list (likely an IRK / resolving-list issue with
   public-address BLE devices). This prevents the controller from auto-
   accepting the remote's connection requests.

2. **BlueZ advertisement-monitor stall** — BlueZ falls back to userspace
   advertisement monitoring, which handles reconnection for hours but
   eventually gets stuck, logging `No matching connection for device`
   indefinitely with no recovery.

Restarting `bluetoothd` resets BlueZ's internal state and reliably restores
reconnection. Restarting Kodi also works (because LibreELEC restarts
bluetoothd with it), but is unnecessarily disruptive.

### Fix

`/storage/.config/bt-monitor.sh` — a watchdog script that:

- Checks remote connection status every 30 seconds
- After 3 consecutive disconnected checks (~90 s), restarts `bluetoothd`
- Re-enables `WakeAllowed` on every reconnection (via `busctl`, since
  `bluetoothctl` segfaults when piped on BlueZ 5.83)
- Logs to syslog under the `bt-monitor` tag

`/storage/.config/system.d/bt-monitor.service`:

```ini
[Unit]
Description=Monitor Shield Remote BLE reconnection
After=bluetooth.target bluetooth.service
Wants=bluetooth.service

[Service]
Type=simple
ExecStart=/bin/bash /storage/.config/bt-monitor.sh
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
```

Enabled with: `systemctl enable bt-monitor.service`

## Power Key vs. Suspend Wake

### Problem

The SHIELD Remote reports `KEY_POWER` in its HID descriptor, and the kernel
tags its input device with `power-switch`. `systemd-logind` watches all
`power-switch` devices for system button presses. With `HandlePowerKey=poweroff`
(the default), pressing the remote's power button to wake from suspend
caused logind to immediately trigger a system poweroff — Kodi received
SIGTERM just ~100 ms after waking.

### Fix

`/storage/.config/logind.conf.d/10-ignore-power-key.conf`:

```ini
[Login]
HandlePowerKey=ignore
HandlePowerKeyLongPress=ignore
```

This tells logind to ignore power key events entirely. Kodi handles its own
shutdown/suspend actions through its UI and JSON-RPC API, so logind doesn't
need to act on them.

> **Note:** `TAG-="power-switch"` in udev rules does not reliably remove the
> tag on systemd 255. The logind.conf override is the working approach.

## Wake Chime (Resume Audio Feedback)

### Problem

After pressing the power button on the SHIELD Remote, the projector and AVR
take several seconds to initialize. There's no immediate feedback that the
system is actually waking up.

### Fix

A sleep.d hook plays a short ascending chime through the laptop's built-in
speakers (ALC285 Analog, `plughw:0,0`) immediately on resume — independent of
the HDMI/AVR audio chain.

This uses LibreELEC's custom sleep hook mechanism (`/storage/.config/sleep.d/`)
rather than a `WantedBy=suspend.target` service, because sleep.d scripts run
*inside* `systemd-suspend.service` before it signals completion — the earliest
userspace hook point available (~1 s earlier than `suspend.target` services).

`/storage/.config/sleep.d/01-wake-chime.power`:

```bash
#!/bin/sh
case "$1" in
    post)
        amixer -c 0 -q set Speaker 70% 2>/dev/null
        amixer -c 0 -q set Master unmute 2>/dev/null
        amixer -c 0 -q set Speaker unmute 2>/dev/null
        aplay -D plughw:0,0 /storage/.config/wake-chime.wav 2>/dev/null &
        ;;
esac
```

The WAV file (`wake-chime.wav`) is generated with Python — three ascending
tones (660 Hz, 880 Hz, 1320 Hz) with fade in/out envelopes, ~0.45 s total.

### Resume timing

The hook chain on "post" resume (scripts in `system-sleep.serial/` sorted
descending, so `99` runs first):

1. `99-suspend-modules.sh` — reloads kernel modules
2. `20-custom-sleep.sh` → **`01-wake-chime.power`** ← chime fires here
3. `10-addon-sleep.sh` — addon hooks
4. `systemd-suspend.service` exits
5. `suspend.target` reached → other resume services start (~1 s later)

## Files Modified on LibreELEC

| File | Purpose |
|------|---------|
| `/storage/.config/autostart.sh` | WOL + BT wakeup chain on boot |
| `/storage/.config/system.d/bt-wake-resume.service` | Re-enable BT USB wakeup sysfs paths after resume |
| `/storage/.config/system.d/bt-monitor.service` | Watchdog: restart bluetoothd if remote stuck disconnected |
| `/storage/.config/bt-monitor.sh` | Watchdog script (used by bt-monitor.service) |
| `/storage/.config/logind.conf.d/10-ignore-power-key.conf` | Prevent logind from triggering poweroff on SHIELD Remote power key |
| `/storage/.config/sleep.d/01-wake-chime.power` | Play chime through laptop speakers on resume (earliest hook) |
| `/storage/.config/wake-chime.wav` | Generated chime audio (3 ascending tones) |

## Useful Commands

```bash
# Check WOL settings
ethtool eth0 | grep -i wake

# Check USB wakeup chain
for d in 4-1.3 4-1 usb4; do echo -n "$d: "; cat /sys/bus/usb/devices/$d/power/wakeup; done

# Check ACPI wakeup sources
grep -E 'XHC|TXHC|RP05' /proc/acpi/wakeup

# Check BT WakeAllowed
bluetoothctl info 3C:6D:66:19:95:D0 | grep Wake

# Check bt-monitor logs
journalctl -t bt-monitor --no-pager

# Check battery
cat /sys/class/power_supply/BAT0/uevent

# Send WOL from Home Assistant
curl -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"mac": "00:50:b6:9d:3b:5c"}' \
  https://ha.apps.lasath.com/api/services/wake_on_lan/send_magic_packet
```

## Shield Remote "find" (HA `shell_command`)

The Shield Remote (BLE HID) has a buzzer reachable over GATT. Home
Assistant exposed two shell_commands that ssh'd into the HTPC and
poked the BlueZ D-Bus interface to start/stop the buzzer — used as a
"find my remote" helper.

Defined in `ha-config/configuration.yaml` (removed at T480 cutover
because the T480 setup has no Shield Remote):

```yaml
shell_command:
  find_shield_remote: >-
    ssh -i /config/.ssh/id_ed25519
    -o UserKnownHostsFile=/config/.ssh/known_hosts
    -o BatchMode=yes -o ConnectTimeout=5
    root@theatre.home.lasath.com
    'busctl call org.bluez /org/bluez/hci0/dev_3C_6D_66_19_95_D0/service001b/char001c
    org.bluez.GattCharacteristic1 WriteValue "aya{sv}" 1 2 0'
  stop_find_shield_remote: >-
    ssh -i /config/.ssh/id_ed25519
    -o UserKnownHostsFile=/config/.ssh/known_hosts
    -o BatchMode=yes -o ConnectTimeout=5
    root@theatre.home.lasath.com
    'busctl call org.bluez /org/bluez/hci0/dev_3C_6D_66_19_95_D0/service001b/char001c
    org.bluez.GattCharacteristic1 WriteValue "aya{sv}" 1 0 0'
```

The two commands write a single byte to GATT characteristic
`service001b/char001c` on device `3C:6D:66:19:95:D0`: `2` = buzz on,
`0` = buzz off. The characteristic path was discovered via
`bluetoothctl menu gatt` / `list-attributes`. If reimplementing for
another BLE remote, the device address and char path will differ;
the `busctl` invocation pattern is reusable.

The HA `script.find_shield_remote` wrapper (also removed at cutover)
called them with a 10 s delay between on and off:

```yaml
find_shield_remote:
  alias: "Theatre: Find Shield Remote"
  icon: mdi:remote
  description: Triggers the buzzer on the NVIDIA Shield Remote to help locate it.
  sequence:
    - action: shell_command.find_shield_remote
    - delay:
        seconds: 10
    - action: shell_command.stop_find_shield_remote
```
