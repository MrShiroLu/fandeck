<p align="center"><img src="docs/icon.png" width="128" alt="wallMatch icon"></p>

<h1 align="center">wallMatch</h1>

<p align="center">Pick a wallpaper, and the rest of your Mac follows: the kitty terminal, the system accent color, and the app itself.</p>

---

wallMatch is a small macOS app built around [pywal](https://github.com/eylles/pywal16). When you set a wallpaper it:

- puts the image on **every Space** (not just the one you're on),
- generates a 16-color palette from it,
- reloads **kitty** with that palette, open windows included,
- sets the macOS **accent color** to the closest system color, so folders, selections and buttons match,
- recolors its own window to the new palette.

## Features

- **Gallery** of every image in your wallpaper folders. Click one to apply it, or drop any image onto the window.
- **Wallpaper folders**: choose which folders to read from. Subfolders are included. Images from elsewhere are copied into the primary folder so they don't disappear.
- **Collage**: combine up to 9 images in a grid, feature, column or row layout. Spacing, corner radius and background are adjustable. The result is rendered at your screen's native resolution.
- **Schedule**: switch wallpapers by day and time, for example a bright one on weekday mornings and a darker one every evening. Each rule holds until the next one fires. Missed rules catch up after sleep.
- **Follows System Settings**: if you change the wallpaper somewhere else, the colors still update.
- **Menu bar**: shuffle, regenerate colors, toggle the schedule. Closing the window keeps the app running in the menu bar.
- **Setup page**: checks for Homebrew, Python and pywal and installs what's missing. It also connects kitty and turns on open at login.

## Requirements

- macOS 14 or later, Apple silicon
- Xcode Command Line Tools (to build)
- Homebrew, Python 3 and pywal16. The Setup page can install the last two for you.

## Install

From a clone of this repo:

```sh
./build.sh
open build/wallMatch.app
```

On first launch wallMatch moves itself to `/Applications`, relaunches from there, and turns on **Open at login**, so the schedule and System Settings sync keep running. You can turn the login item off on the **Setup** tab, and it stays off. Then go through the rest of the Setup tab.

`./build.sh --install` copies the app straight to `/Applications` instead.

To use only the script without the app:

```sh
pipx install pywal16
python3 wallmatch.py --set ~/Pictures/some-wallpaper.jpg
```

## kitty

The Setup page adds this line to the top of `~/.config/kitty/kitty.conf` (a backup is kept):

```conf
include ~/.cache/wal/colors-kitty.conf
```

Anything later in your config, such as `background_opacity`, still overrides it. wallMatch sends kitty `SIGUSR1` to reload the config.

## How it works

| Piece | What it does |
| --- | --- |
| `wallmatch.py` | Runs `wal` on the image, picks the most vivid palette color, maps it to the nearest `AppleAccentColor` and posts the color-change notifications. With `--set`, it also writes the wallpaper to every Space. |
| `app/` | The SwiftUI app. It runs the bundled script, and watches the wallpaper store to catch changes made in System Settings. |
| `tools/make-icon.swift` | Draws the app icon with CoreGraphics. `tools/make-icon.sh` turns it into `AppIcon.icns`. |

macOS's `NSWorkspace.setDesktopImageURL` only changes the current Space. To set the wallpaper everywhere, `wallmatch.py --set` writes the same record that **Show on all Spaces** in System Settings writes. That record lives in `~/Library/Application Support/com.apple.wallpaper/Store/Index.plist`. The script then restarts `WallpaperAgent` so the change is picked up.

## Limitations

- macOS only offers eight accent colors (graphite plus seven hues), so the accent is the closest match, not the exact color. Mostly gray wallpapers give graphite.
- Other apps' window backgrounds can't be themed system-wide. Apps with pywal support (VS Code, Firefox through pywalfox, and others) can read `~/.cache/wal` themselves.
- Applying a wallpaper from wallMatch replaces per-Space wallpapers with a single one.
- The app is ad-hoc signed. The first time you open it, macOS may ask you to confirm in System Settings › Privacy & Security.
