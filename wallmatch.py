#!/opt/homebrew/bin/python3
"""Match colors to the wallpaper: pywal palette -> kitty, macOS accent and highlight colors."""
import colorsys
import fcntl
import json
import os
import plistlib
import shutil
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

WAL_CACHE = Path.home() / ".cache/wal"
WALLPAPER_STORE = Path.home() / "Library/Application Support/com.apple.wallpaper/Store/Index.plist"
WAL = shutil.which("wal") or str(Path.home() / ".local/bin/wal")

# macOS's fixed accent colors (AppleAccentColor value -> approximate hue in degrees)
ACCENT_HUES = {0: 0, 1: 30, 2: 52, 3: 120, 4: 210, 5: 280, 6: 330}
GRAPHITE = -1


def current_wallpaper():
    js = 'ObjC.import("AppKit"); $.NSWorkspace.sharedWorkspace.desktopImageURLForScreen($.NSScreen.mainScreen).path.js'
    out = subprocess.run(["osascript", "-l", "JavaScript", "-e", js], capture_output=True, text=True)
    return out.stdout.strip()


def hex_to_rgb(h):
    h = h.lstrip("#")
    return tuple(int(h[i:i + 2], 16) / 255 for i in (0, 2, 4))


def pick_accent(colors):
    """Pick the most vivid color from the wal palette (color1...color6)."""
    def score(h):
        _, s, v = colorsys.rgb_to_hsv(*hex_to_rgb(h))
        return s * v
    return max((colors[f"color{i}"] for i in range(1, 7)), key=score)


def nearest_accent(rgb):
    h, s, v = colorsys.rgb_to_hsv(*rgb)
    if s < 0.18 or v < 0.2:
        return GRAPHITE
    hue = h * 360
    return min(ACCENT_HUES, key=lambda k: min(abs(hue - ACCENT_HUES[k]), 360 - abs(hue - ACCENT_HUES[k])))


def set_macos_colors(accent_hex):
    rgb = hex_to_rgb(accent_hex)
    accent = nearest_accent(rgb)
    # The highlight color can be any RGB; mix with white so selected text stays readable
    light = tuple(c * 0.6 + 0.4 for c in rgb)
    subprocess.run(["defaults", "write", "-g", "AppleAccentColor", "-int", str(accent)], check=True)
    subprocess.run(["defaults", "write", "-g", "AppleHighlightColor", "-string",
                    "{:.6f} {:.6f} {:.6f} Other".format(*light)], check=True)
    # Tell running apps that the colors changed
    js = ('ObjC.import("Foundation"); var c = $.NSDistributedNotificationCenter.defaultCenter;'
          '["AppleColorPreferencesChangedNotification", "AppleAquaColorVariantChanged"].forEach(function (n) {'
          ' c.postNotificationNameObjectUserInfoDeliverImmediately(n, $(), $(), true); });')
    subprocess.run(["osascript", "-l", "JavaScript", "-e", js], capture_output=True)
    return accent


def set_wallpaper_everywhere(path):
    """Same wallpaper on every Space: writes the same record as "Show on all Spaces" in System Settings.
    NSWorkspace only changes the active Space, so this goes through Index.plist directly."""
    store = plistlib.loads(WALLPAPER_STORE.read_bytes())
    now = datetime.now(timezone.utc).replace(tzinfo=None)
    config = plistlib.dumps({"type": "imageFile", "url": {"relative": Path(path).as_uri()}}, fmt=plistlib.FMT_BINARY)
    content = {"Choices": [{"Configuration": config, "Files": [], "Provider": "com.apple.wallpaper.choice.image"}],
               "Shuffle": "$null"}
    # Keep the existing fit option (fill, center, ...) from one of the current entries
    for d in [store.get("AllSpacesAndDisplays", {}), *store.get("Displays", {}).values()]:
        if "EncodedOptionValues" in d.get("Desktop", {}).get("Content", {}):
            content["EncodedOptionValues"] = d["Desktop"]["Content"]["EncodedOptionValues"]
            break
    everywhere = store.setdefault("AllSpacesAndDisplays", {})
    everywhere["Desktop"] = {"Content": content, "LastSet": now, "LastUse": now}
    everywhere["Type"] = "individual"
    store["Displays"] = {}
    store["Spaces"] = {}
    WALLPAPER_STORE.write_bytes(plistlib.dumps(store, fmt=plistlib.FMT_BINARY))
    # WallpaperAgent keeps the store in memory; launchd restarts it and it reads the new one
    subprocess.run(["killall", "WallpaperAgent"], capture_output=True)


def reload_kitty():
    # On SIGUSR1 kitty reloads kitty.conf, including the wal colors it includes
    subprocess.run(["pkill", "-USR1", "-x", "kitty"])


def main():
    args = sys.argv[1:]
    force = "--force" in args
    paths = [a for a in args if not a.startswith("--")]
    wallpaper = paths[0] if paths else current_wallpaper()
    if not wallpaper or not os.path.isfile(wallpaper):
        print(f"wallpaper file not found: {wallpaper!r}")
        return 1

    # If two runs start at once, the second waits here and then exits via the cache check
    WAL_CACHE.mkdir(parents=True, exist_ok=True)
    lock = open(WAL_CACHE / "wallmatch.lock", "w")
    fcntl.flock(lock, fcntl.LOCK_EX)

    if "--set" in args:
        set_wallpaper_everywhere(wallpaper)

    last = WAL_CACHE / "wal"
    if not force and last.exists() and last.read_text().strip() == wallpaper:
        return 0

    # -n: don't let wal set the wallpaper, -s/-t: no terminal sequences (we reload kitty), -e: no other reloads
    subprocess.run([WAL, "-n", "-s", "-t", "-e", "-q", "-i", wallpaper], check=True)

    colors = json.loads((WAL_CACHE / "colors.json").read_text())["colors"]
    accent_hex = pick_accent(colors)
    accent = set_macos_colors(accent_hex)
    reload_kitty()
    print(f"{os.path.basename(wallpaper)} -> accent {accent_hex} (AppleAccentColor={accent})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
