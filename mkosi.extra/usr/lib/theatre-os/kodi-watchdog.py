#!/usr/bin/env python3
# theatre-os: long-press KEY_POWER on any input device → restart kodi-gbm.
#
# Escape hatch for when Kodi doesn't recover from a display-state change
# (projector off at boot, AVR mode switch, HDMI handshake confusion).
# Hold the remote's power button for >= HOLD_SECONDS; service runs
# `systemctl restart kodi-gbm.service`, which works whether Kodi or
# moonlight/sway is currently active (the Conflicts= machinery on the
# moonlight unit handles the moonlight case).
#
# Runs as root. The script is intentionally small and does exactly one
# thing — see README → Kodi & moonlight session for the rationale on
# not bothering with polkit/sudo for a 30-line escape hatch.
#
# Safe re: logind: HandlePowerKey=ignore + HandlePowerKeyLongPress=ignore
# are set in 10-ignore-power-key.conf, so KEY_POWER won't also trigger
# shutdown.

import asyncio
import logging
import subprocess
import sys

import evdev
import pyudev

HOLD_SECONDS = 3.0
TARGET_UNIT = "kodi-gbm.service"

log = logging.getLogger("kodi-watchdog")


def device_has_power_key(device: evdev.InputDevice) -> bool:
    """True iff the device reports it can emit KEY_POWER. Cheaper than
    grabbing every keyboard-shaped device — most don't have a power key."""
    caps = device.capabilities().get(evdev.ecodes.EV_KEY, [])
    return evdev.ecodes.KEY_POWER in caps


async def watch_device(device: evdev.InputDevice) -> None:
    """Read events from one device forever; trigger restart on long-press."""
    log.info("watching %s (%s)", device.path, device.name)
    pending_task: asyncio.Task | None = None

    try:
        async for event in device.async_read_loop():
            if event.type != evdev.ecodes.EV_KEY:
                continue
            if event.code != evdev.ecodes.KEY_POWER:
                continue

            # value: 0 = up, 1 = down, 2 = repeat. Repeats are noise here —
            # the timer is what tracks the hold duration.
            if event.value == 1:
                if pending_task is None or pending_task.done():
                    pending_task = asyncio.create_task(trigger_after_hold())
            elif event.value == 0:
                if pending_task is not None and not pending_task.done():
                    pending_task.cancel()
                    pending_task = None
    except OSError as e:
        # Device went away (unplug, sleep, etc.). pyudev will give us
        # a new one if/when it reappears.
        log.info("device %s closed: %s", device.path, e)


async def trigger_after_hold() -> None:
    """Wait HOLD_SECONDS; if not cancelled by key-up, restart kodi."""
    try:
        await asyncio.sleep(HOLD_SECONDS)
    except asyncio.CancelledError:
        return
    log.warning("KEY_POWER held >=%.1fs — restarting %s", HOLD_SECONDS, TARGET_UNIT)
    # Fire and forget. If systemctl fails, log it; don't crash the watcher.
    try:
        subprocess.run(
            ["systemctl", "restart", TARGET_UNIT],
            check=True,
            capture_output=True,
            text=True,
            timeout=30,
        )
    except subprocess.CalledProcessError as e:
        log.error("systemctl restart failed: %s\n%s", e, e.stderr)
    except subprocess.TimeoutExpired:
        log.error("systemctl restart timed out")


async def main() -> None:
    logging.basicConfig(
        level=logging.INFO,
        format="%(levelname)s %(name)s: %(message)s",
        stream=sys.stderr,
    )

    watched: dict[str, asyncio.Task] = {}

    def add_device(path: str) -> None:
        if path in watched and not watched[path].done():
            return
        try:
            dev = evdev.InputDevice(path)
        except (OSError, PermissionError) as e:
            log.debug("skip %s: %s", path, e)
            return
        if not device_has_power_key(dev):
            return
        watched[path] = asyncio.create_task(watch_device(dev))

    # Pick up devices that already exist at start.
    for path in evdev.list_devices():
        add_device(path)

    # Subscribe to udev hot-plug for the input subsystem so a dongle
    # replug or wake-from-suspend reappearance gets picked up without
    # restarting the service.
    context = pyudev.Context()
    monitor = pyudev.Monitor.from_netlink(context)
    monitor.filter_by(subsystem="input")
    monitor.start()

    loop = asyncio.get_running_loop()

    def on_udev_event() -> None:
        device = monitor.poll(timeout=0)
        if device is None:
            return
        if device.action != "add":
            return
        node = device.device_node
        if node and node.startswith("/dev/input/event"):
            add_device(node)

    loop.add_reader(monitor.fileno(), on_udev_event)

    # Sleep forever; the per-device tasks do the real work.
    await asyncio.Event().wait()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass
