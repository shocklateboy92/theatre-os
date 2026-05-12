import json
import os
import time
import sys
import urllib.request
import xbmc
import xbmcaddon
import xbmcgui
import xbmcplugin
import xbmcvfs

ADDON = xbmcaddon.Addon()
HANDLE = int(sys.argv[1])

API_URL = "https://watchlist.apps.lasath.com/api/kodi/watchlist"
API_TOKEN = "ivoohaechuiMooveisohxe7johhaagheij8ithohchei5ia9Quaefiz2Voh4muab"
JELLYFIN_USER_ID = "937c2176617b424daf678508fcf4e68e"

CACHE_DIR = xbmcvfs.translatePath(ADDON.getAddonInfo("profile"))
CACHE_FILE = os.path.join(CACHE_DIR, "watchlist_cache.json")
CACHE_TTL = 300  # 5 minutes


def log(msg, level=xbmc.LOGINFO):
    xbmc.log("Watchlist: {}".format(msg), level)


def fetch_watchlist():
    """Fetch ordered movie list from external API, with file cache."""
    # Check cache
    if os.path.exists(CACHE_FILE):
        try:
            age = time.time() - os.path.getmtime(CACHE_FILE)
            if age < CACHE_TTL:
                with open(CACHE_FILE, "r") as f:
                    return json.load(f)
        except (OSError, ValueError):
            pass

    # Fetch from API
    req = urllib.request.Request(API_URL, headers={
        "Authorization": "Bearer " + API_TOKEN,
    })
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            data = json.loads(resp.read())
    except Exception as e:
        log("API fetch failed: {}".format(e), xbmc.LOGERROR)
        # Return stale cache if available
        if os.path.exists(CACHE_FILE):
            with open(CACHE_FILE, "r") as f:
                return json.load(f)
        return []

    # Write cache
    if not os.path.exists(CACHE_DIR):
        os.makedirs(CACHE_DIR)
    with open(CACHE_FILE, "w") as f:
        json.dump(data, f)

    return data


def get_kodi_movies():
    """Fetch all movies from Kodi library with metadata, indexed by IMDB ID."""
    result = json.loads(xbmc.executeJSONRPC(json.dumps({
        "jsonrpc": "2.0",
        "method": "VideoLibrary.GetMovies",
        "params": {
            "properties": [
                "title", "year", "genre", "plot", "runtime", "rating",
                "uniqueid", "file", "art", "playcount", "lastplayed",
                "director", "mpaa", "studio", "tagline", "trailer",
                "resume",
            ],
        },
        "id": 1,
    })))

    movies = result.get("result", {}).get("movies", [])
    by_imdb = {}
    for movie in movies:
        imdb_id = movie.get("uniqueid", {}).get("imdb")
        if imdb_id:
            by_imdb[imdb_id] = movie
    return by_imdb


def make_list_item(movie):
    """Create a rich ListItem from Kodi library movie data."""
    li = xbmcgui.ListItem(movie["title"])

    info_tag = li.getVideoInfoTag()
    info_tag.setTitle(movie.get("title", ""))
    info_tag.setYear(movie.get("year", 0))
    info_tag.setPlot(movie.get("plot", ""))
    info_tag.setMpaa(movie.get("mpaa", ""))
    info_tag.setTagLine(movie.get("tagline", ""))
    info_tag.setRating(movie.get("rating", 0.0))
    info_tag.setPlaycount(movie.get("playcount", 0))
    info_tag.setLastPlayed(movie.get("lastplayed", ""))
    info_tag.setMediaType("movie")
    info_tag.setDbId(movie.get("movieid", -1))

    genres = movie.get("genre", [])
    if genres:
        info_tag.setGenres(genres)

    directors = movie.get("director", [])
    if directors:
        info_tag.setDirectors(directors)

    studios = movie.get("studio", [])
    if studios:
        info_tag.setStudios(studios)

    duration = movie.get("runtime", 0)
    if duration:
        info_tag.setDuration(duration)

    trailer = movie.get("trailer", "")
    if trailer:
        info_tag.setTrailer(trailer)

    art = movie.get("art", {})
    if art:
        li.setArt(art)

    # Set overlay explicitly — ListItem.Overlay is not auto-set for plugin items
    playcount = movie.get("playcount", 0)
    if playcount > 0:
        li.setInfo("video", {"overlay": 5})  # ICON_OVERLAY_WATCHED
    else:
        li.setInfo("video", {"overlay": 4})  # ICON_OVERLAY_UNWATCHED

    resume = movie.get("resume", {})
    position = resume.get("position", 0)
    total = resume.get("total", 0)
    if position > 0:
        info_tag.setResumePoint(float(position), float(total))

    li.setProperty("IsPlayable", "true")
    li.setProperty("totaltime", str(total))
    li.setProperty("resumetime", str(position))
    return li


def jellyfin_play_url(jellyfin_id):
    """Construct a Jellyfin plugin play URL as fallback."""
    return "plugin://plugin.video.jellyfin/{}/?mode=play&id={}".format(
        JELLYFIN_USER_ID, jellyfin_id
    )


def main():
    watchlist = fetch_watchlist()
    if not watchlist:
        xbmcplugin.endOfDirectory(HANDLE, succeeded=False)
        return

    kodi_movies = get_kodi_movies()

    items = []
    for entry in watchlist:
        imdb_id = entry.get("imdbId", "")
        jellyfin_id = entry.get("jellyfinId", "")

        movie = kodi_movies.get(imdb_id)
        if movie:
            li = make_list_item(movie)
            url = movie["file"]
            items.append((url, li, False))
        elif jellyfin_id:
            # Movie not in Kodi library — use Jellyfin plugin as fallback
            li = xbmcgui.ListItem("Movie ({})".format(imdb_id))
            li.setProperty("IsPlayable", "true")
            url = jellyfin_play_url(jellyfin_id)
            items.append((url, li, False))
            log("{} not in library, using Jellyfin fallback".format(imdb_id))
        else:
            log("{} not in library and no Jellyfin ID".format(imdb_id), xbmc.LOGWARNING)

    xbmcplugin.setContent(HANDLE, "movies")
    xbmcplugin.addSortMethod(HANDLE, xbmcplugin.SORT_METHOD_NONE)
    xbmcplugin.addDirectoryItems(HANDLE, items, len(items))
    xbmcplugin.endOfDirectory(HANDLE, updateListing=False, cacheToDisc=False)


if __name__ == "__main__":
    main()
