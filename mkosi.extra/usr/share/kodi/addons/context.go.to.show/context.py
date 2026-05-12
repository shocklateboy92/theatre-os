import sys
import json
import xbmc
import xbmcgui


def main():
    info_tag = sys.listitem.getVideoInfoTag()
    media_type = info_tag.getMediaType()
    dbid = info_tag.getDbId()

    if dbid <= 0:
        xbmcgui.Dialog().notification("Go to Show", "Item not in library", xbmcgui.NOTIFICATION_WARNING)
        return

    tvshowid = None

    if media_type == "episode":
        result = json.loads(xbmc.executeJSONRPC(json.dumps({
            "jsonrpc": "2.0",
            "method": "VideoLibrary.GetEpisodeDetails",
            "params": {"episodeid": dbid, "properties": ["tvshowid"]},
            "id": 1,
        })))
        tvshowid = result.get("result", {}).get("episodedetails", {}).get("tvshowid")

    elif media_type == "season":
        result = json.loads(xbmc.executeJSONRPC(json.dumps({
            "jsonrpc": "2.0",
            "method": "VideoLibrary.GetSeasonDetails",
            "params": {"seasonid": dbid, "properties": ["tvshowid"]},
            "id": 1,
        })))
        tvshowid = result.get("result", {}).get("seasondetails", {}).get("tvshowid")

    if tvshowid:
        xbmc.executebuiltin(
            "ActivateWindow(Videos,videodb://tvshows/titles/%s/,return)" % tvshowid
        )
    else:
        xbmcgui.Dialog().notification("Go to Show", "Could not find parent show", xbmcgui.NOTIFICATION_WARNING)


if __name__ == "__main__":
    main()
