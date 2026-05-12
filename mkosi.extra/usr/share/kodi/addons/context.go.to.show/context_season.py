import sys
import json
import xbmc
import xbmcgui


def main():
    info_tag = sys.listitem.getVideoInfoTag()
    media_type = info_tag.getMediaType()
    dbid = info_tag.getDbId()

    if media_type != "episode" or dbid <= 0:
        xbmcgui.Dialog().notification("Go to Season", "Item not in library", xbmcgui.NOTIFICATION_WARNING)
        return

    result = json.loads(xbmc.executeJSONRPC(json.dumps({
        "jsonrpc": "2.0",
        "method": "VideoLibrary.GetEpisodeDetails",
        "params": {"episodeid": dbid, "properties": ["tvshowid", "season", "episode"]},
        "id": 1,
    })))
    details = result.get("result", {}).get("episodedetails", {})
    tvshowid = details.get("tvshowid")
    season_num = details.get("season")
    episode_num = details.get("episode")

    if not tvshowid or season_num is None:
        xbmcgui.Dialog().notification("Go to Season", "Could not find show/season", xbmcgui.NOTIFICATION_WARNING)
        return

    xbmc.executebuiltin(
        "ActivateWindow(Videos,videodb://tvshows/titles/%s/%s/,return)" % (tvshowid, season_num)
    )

    if episode_num is not None and episode_num > 0:
        # Wait for the container to have items (window must load first)
        for i in range(100):  # up to ~10 seconds
            xbmc.sleep(100)
            num_items = int(xbmc.getInfoLabel("Container.NumItems") or "0")
            if num_items > 0 and not xbmc.getCondVisibility("Container.IsUpdating"):
                break
        container_id = xbmc.getInfoLabel("System.CurrentControlId")
        # Episodes are sorted by episode number; position is 1-based
        xbmc.executebuiltin("SetFocus(%s,%d)" % (container_id, episode_num))


if __name__ == "__main__":
    main()
