import json
import time
import urllib.request
import xbmc

MIN_INTERVAL = 0.1  # seconds between volume commands

HA_SERVER = "https://ha.apps.lasath.com"
HA_TOKEN = (
    "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9."
    "eyJpc3MiOiIwOTAzNDkwYzI0Nzc0Mzg4YmNmMDk1YjYzZWNiZDk0ZSIsImlhdCI6MTc3NTUzNjU0NCwiZXhwIjoyMDkwODk2NTQ0fQ."
    "tTQOVvXYlXs1syA5eckDuXhWAGiTZ7mwTgU_52VkQzQ"
)
ENTITY = "media_player.denon_avr_s970h"


def ha_request(path, data=None):
    headers = {
        "Authorization": "Bearer " + HA_TOKEN,
        "Content-Type": "application/json",
    }
    body = json.dumps(data).encode() if data else None
    req = urllib.request.Request(HA_SERVER + path, data=body, headers=headers)
    with urllib.request.urlopen(req, timeout=5) as resp:
        return json.loads(resp.read())


def volume_up():
    ha_request("/api/services/media_player/volume_up", {"entity_id": ENTITY})


def volume_down():
    ha_request("/api/services/media_player/volume_down", {"entity_id": ENTITY})


def volume_mute():
    state = ha_request("/api/states/" + ENTITY)
    muted = state.get("attributes", {}).get("is_volume_muted", False)
    ha_request("/api/services/media_player/volume_mute", {
        "entity_id": ENTITY,
        "is_volume_muted": not muted,
    })


ACTIONS = {
    "up": volume_up,
    "down": volume_down,
    "mute": volume_mute,
}


class AVRVolumeMonitor(xbmc.Monitor):
    def __init__(self):
        super().__init__()
        self._last_call = 0

    def onNotification(self, sender, method, data):
        if sender != "service.avr.volume":
            return
        now = time.monotonic()
        if now - self._last_call < MIN_INTERVAL:
            return
        self._last_call = now
        # method arrives as "Other.{action}"
        action = method.split(".", 1)[-1] if "." in method else method
        handler = ACTIONS.get(action)
        if handler:
            try:
                handler()
            except Exception as e:
                xbmc.log("AVR Volume: {} failed: {}".format(action, e), xbmc.LOGERROR)


if __name__ == "__main__":
    monitor = AVRVolumeMonitor()
    xbmc.log("AVR Volume: service started", xbmc.LOGINFO)
    monitor.waitForAbort()
    xbmc.log("AVR Volume: service stopped", xbmc.LOGINFO)
