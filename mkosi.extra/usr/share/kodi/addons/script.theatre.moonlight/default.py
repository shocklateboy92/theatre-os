"""Launch moonlight via systemd.

Pure trigger: fires `systemctl start theatre-os-moonlight.service`
and exits. The unit is wired with Conflicts=kodi-gbm.service so it
auto-stops Kodi (releasing DRM master), and ExecStopPost= brings
Kodi back when moonlight exits. See theatre-os README → Kodi &
moonlight session for the full handoff design.

The kodi user is allowed to invoke this one unit without auth via
/etc/polkit-1/rules.d/10-theatre-os-moonlight.rules.
"""
import subprocess
import xbmc

ADDON_ID = "script.theatre.moonlight"
UNIT = "theatre-os-moonlight.service"


def log(msg, level=xbmc.LOGINFO):
    xbmc.log("[{}] {}".format(ADDON_ID, msg), level)


def main():
    # --no-block so systemctl returns immediately rather than waiting
    # for the unit to reach `active`. Kodi is about to be killed by
    # the unit's Conflicts= anyway; if we waited we'd be racing our
    # own teardown.
    try:
        subprocess.check_call(["systemctl", "--no-block", "start", UNIT])
        log("Started {}".format(UNIT))
    except subprocess.CalledProcessError as e:
        log("Failed to start {}: exit {}".format(UNIT, e.returncode), xbmc.LOGERROR)
    except FileNotFoundError:
        log("systemctl not on PATH", xbmc.LOGERROR)


if __name__ == "__main__":
    main()
