"""Toggle a Home Assistant light entity from Kodi.

Reads HA server URL and long-lived access token from the HAKA
(script.program.homeassistant) addon settings so we don't duplicate
credentials. Defaults to toggling light.kitchen_cabinet_lights; pass
a different entity_id as sys.argv[1] to override.
"""
import sys
import json
import urllib.request
import xbmc
import xbmcaddon

DEFAULT_ENTITY = "light.kitchen_cabinet_lights"
ADDON_ID = "script.theatre.lights.toggle"


def log(msg, level=xbmc.LOGINFO):
    xbmc.log("[{}] {}".format(ADDON_ID, msg), level)


def main():
    entity_id = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_ENTITY

    haka = xbmcaddon.Addon("script.program.homeassistant")
    base_url = haka.getSetting("haServer").rstrip("/")
    token = haka.getSetting("haToken")

    if not base_url or not token:
        log("Missing HA server/token in HAKA settings", xbmc.LOGERROR)
        return

    url = "{}/api/services/light/toggle".format(base_url)
    body = json.dumps({"entity_id": entity_id}).encode("utf-8")
    req = urllib.request.Request(
        url,
        data=body,
        headers={
            "Authorization": "Bearer {}".format(token),
            "Content-Type": "application/json",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=5) as resp:
            log("Toggled {} (HTTP {})".format(entity_id, resp.status))
    except Exception as e:
        log("Toggle failed for {}: {}".format(entity_id, e), xbmc.LOGERROR)


if __name__ == "__main__":
    main()
