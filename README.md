# Tile

A personal macOS window manager, a menu-bar app. It does four things:

- **Snapping.** It snaps windows into layouts you define, on shortcuts you define.
- **Display profiles.** It knows your display setups, and shortcuts can act differently per display (top/bottom on a portrait monitor, left/right on the laptop).
- **Arrangements.** One shortcut launches your apps and puts each window on the right screen and the right native desktop (Space), so the 4-finger swipe finds everything in place.
- **Capture.** You lay windows out by hand and Capture saves them as an arrangement.

It uses no SIP changes, injects nothing into the Dock, and fakes no workspaces off-screen.

## Build and install

You need macOS 15 or later and Xcode, at `/Applications/Xcode.app` by default.

```sh
./build.sh install   # release build, sign, copy to ~/Applications/Tile.app, relaunch
./build.sh test      # unit tests (swift test)
./build.sh release   # Developer ID build, notarized: dist/Tile-<version>.zip + .sha256 for Homebrew
```

`build.sh` signs with the `Apple Development` identity. To use another one, set `TILE_SIGN_IDENTITY`.

**Never ad-hoc sign.** The Accessibility grant is tied to the code signature, and an ad-hoc signature changes with every build.

On first launch Tile asks for Accessibility. Grant it in System Settings › Privacy & Security › Accessibility; Tile notices without a relaunch.

If the grant gets stuck (the toggle is on but Tile says it isn't), reset it and grant it again:

```sh
tccutil reset Accessibility com.epsilonlimited.tile
```

To start Tile at login, turn on **Launch at Login** in its menu. It uses `SMAppService`, so the login item shows in System Settings › General › Login Items.

## macOS settings arrangements need

Tile checks these at launch and lists any that are wrong at the top of its menu.

| Setting | Must be | Fix |
|---|---|---|
| Automatically rearrange Spaces based on most recent use | off | `defaults write com.apple.dock mru-spaces -bool false && killall Dock` |
| Displays have separate Spaces | on | System Settings › Desktop & Dock › Mission Control (then log out) |
| Switch to Desktop N shortcuts | on, one for every desktop | System Settings › Keyboard › Keyboard Shortcuts › Mission Control |
| Dock › Options › Assign To | None, for apps in arrangements | right-click the app's Dock icon |

- **Rearranging Spaces.** If it's on, macOS reorders desktops as you use them, and "desktop 2" stops meaning anything.
- **Desktop N shortcuts.** Tile switches desktops by posting these shortcuts. macOS only lists them for desktops that exist, and only up to Desktop 16.
- **Numbering across displays.** Desktop N counts the desktops of every display together, in the window server's display order, not left to right. On this machine that's the built-in display, then Vertical-Right, then Vertical-Left. Tile works the numbering out itself; arrangements just say "vertical-right, desktop 2".
- **Assign To.** An app pinned to a desktop gets moved back there by macOS. Tile warns about it in the arrangement report.
- **Reduce motion.** System Settings › Accessibility › Display › Reduce motion makes desktop switches much faster, and arrangements with them.

## The config file

It lives at `~/.config/tile/config.json` and is written with defaults on first launch. Tile watches the file and reloads on every save. Use **Open Config File** in the menu to edit it.

A broken file never replaces a working one. Tile keeps the last good config, turns its menu bar icon into a warning triangle, and shows each problem in the menu with its path (`bindings[3].layout: no layout has id 'lefthalf'`).

```jsonc
{
  "gaps": { "outer": 10, "inner": 10 },        // points: at the screen edge, and between windows
  "ignoredApps": ["com.apple.FaceTime"],       // bundle ids Tile never moves, and Capture skips
  "profiles": [ ... ],
  "layouts": [ ... ],
  "bindings": [ ... ],
  "arrangements": [ ... ],
  "grab": { "com.google.Chrome": [400, 8] }    // optional, see Arrangements
}
```

The file is plain JSON, so it can't hold comments. The comments above are only for this README.

### Layouts

Each layout is one of three forms:

- **Rect:** fractions of the screen's visible frame (inside the menu bar and Dock), from its top-left corner.
- **Grid:** pick a block of cells from a grid.
- **Center:** centers the window and keeps its size.

```json
{ "id": "left-half", "name": "Left Half", "rect": [0, 0, 0.5, 1] },
{ "id": "middle-third", "name": "Middle Third", "grid": [1, 3], "cells": [0, 1, 1, 1] },
{ "id": "center", "name": "Center", "center": true }
```

For a grid, `grid` is `[columns, rows]` and `cells` is `[column, row, columnSpan, rowSpan]`, counting from 0.

### Bindings

A binding maps a shortcut to exactly one of these:

- `"layout"`
- `"cycle"`: repeated presses step through its layouts while the window stays where the last press put it.
- `"action"`: `restore`, `next-display` or `previous-display`.
- `"arrange"`: runs an arrangement.

```json
{ "keys": "ctrl+opt+left", "cycle": ["left-half", "left-third", "left-two-thirds"] },
{ "keys": "ctrl+opt+left", "when": { "orientation": "portrait" }, "cycle": ["top-half", "top-third", "top-two-thirds"] },
{ "keys": "opt+f", "layout": "full" },
{ "keys": "hyper+w", "arrange": "work" }
```

**Key strings.**

- Modifiers: `ctrl`, `opt`, `shift`, `cmd`, and `hyper`, which is all four.
- Keys: letters, digits, arrows, `return`, `space`, `tab`, `escape`, `delete`, `f1` to `f20`, and punctuation (`;` `'` `,` `.` `/` `[` `]` `-` `=` `` ` `` `\`).
- A US key layout is assumed.
- Bare keys and shift-only keys are refused, except F-keys, because they'd take over typing.
- `opt+letter` works. Older notes said macOS 15 refuses Option-only shortcuts, but macOS 26.2 registers and delivers them. They do stop Option typing the character, so `opt+f` no longer types ƒ.

**`when`.** It narrows a binding to a `profile`, a display role (`display`), or an `orientation` (`portrait` or `landscape`) of the display the focused window is on. Several bindings can share keys. When more than one matches a press, the most specific wins: display, then orientation, then profile, then no `when`. Two bindings with the same keys and the same `when` are an error, because one could never fire.

### Profiles

A profile names the displays it expects and gives each one a role.

**Matching.** Tile picks the first profile whose roles match the connected displays one to one, with the same count. A matcher can use any of these:

- `builtin`
- `name`: macOS's name for the display. The ` (1)`/` (2)` it adds to identical monitors is ignored, since the numbers can swap.
- `serial`: tells identical monitors apart.
- `rotation`: in degrees.

```json
{ "id": "laptop", "displays": { "laptop": { "builtin": true } } },
{ "id": "one-monitor", "displays": { "laptop": { "builtin": true }, "vertical": { "name": "DELL S2722QC" } } },
{ "id": "desk", "onActivate": "work", "displays": {
    "laptop":         { "builtin": true },
    "vertical-left":  { "name": "DELL S2722QC", "serial": 810894658 },
    "vertical-right": { "name": "DELL S2722QC", "serial": 825446978 } } }
```

**Re-matching.** Tile matches again when displays connect or disconnect. It waits 3 seconds for them to settle, so a dock that brings monitors up one at a time doesn't briefly look like the one-monitor setup.

**`onActivate`.** This names the profile's arrangement. Tile runs it in two cases:

- **At login.** The first time Tile starts in a login session, it waits for the displays to settle (6 seconds without a change), then runs the arrangement with launching on. Every app it names opens onto its desktop, and Tile allows each app 60 seconds to show its window. Restarting Tile later in the same session doesn't run it again, so apps you closed on purpose stay closed. Tile goes by the console login time `last` shows, so starting Tile by hand after logging in counts too.
- **On docking.** When plugging displays in or out activates the profile, Tile moves the windows that are already open and opens nothing.

It doesn't run on a config edit or on a manual override. To try the login run without logging out, use **Debug › Run Login Arrangement** or `tile://debug/login`.

**Menu items.**

- **Profile ›** overrides the match by hand. Displays the profile has no role for are ignored. The override lasts until you pick Automatic or the displays stop fitting it.
- **Copy Current Displays as Profile JSON** puts a profile for the connected displays on the clipboard, with serials wherever two monitors share a name.

### Arrangements

An arrangement belongs to one profile, and lists `{display role, desktop}` targets with the windows that go on each. `desktop` counts from 1 among that display's desktops, in Mission Control order.

```json
{ "id": "work", "profile": "desk",
  "endOn": { "laptop": 1, "vertical-left": 1, "vertical-right": 1 },
  "desktops": [
    { "display": "vertical-right", "desktop": 1, "windows": [
        { "app": "com.microsoft.VSCode", "layout": "top-two-thirds", "open": ["~/epsilon"] },
        { "app": "dev.warp.Warp-Stable", "layout": "bottom-third" } ] },
    { "display": "vertical-right", "desktop": 2, "windows": [
        { "app": "com.tinyspeck.slackmacgap", "layout": "top-half" } ] }
  ] }
```

Each window entry has these fields:

- `app`: the bundle id. To find one: `osascript -e 'id of app "Slack"'`
- `title` (optional): a regex that picks one of the app's windows by title. Use it when an app has several windows and nothing to `open`.
- `layout`: a layout id, or `rect` with fractions.
- `open` (optional): files or folders to open with the app, such as a project folder for the editor or a document. This both opens the window and identifies it later:
  - A folder matches a window showing a file inside it, or a window whose title names the folder. VS Code titles name the workspace folder ("Arranger.swift — tile"), and terminals often show the working directory ("~/epsilon/tile").
  - A file matches the window showing that document.
  - URLs (web pages) are opened but never matched, so add a `title` for those.

`endOn` (optional) says which desktop to leave each display on. Without it, Tile goes back to the desktops showing when the run started.

**Running one.** Use its binding, the **Arrangements** menu, `tile://arrange?id=work`, or the profile's `onActivate`.

1. **Missing desktops are added.** macOS drops an external display's extra desktops when it disconnects, so a redocked monitor often comes back with one. Tile opens Mission Control for a moment and presses the display's add-desktop button through Accessibility, the same way Hammerspoon does. If that fails, or a desktop's Desktop N shortcut is off, the windows bound for that desktop fail, and the rest of the arrangement still runs. It only stops before touching anything when Accessibility or the Mission Control settings are wrong, or no display plays a role.
2. **Apps and windows that aren't open** are opened with their target desktop showing, so the window opens there. Tile waits up to 30 seconds for the window, or 60 at login. A placement with `open` opens those files or folders. If a docking run finds a window not open, it skips it.
3. **Windows that are already open** move to their desktop and display:
   - To another display: show the target desktop there, then move the window across.
   - To another desktop of the same display: park the window on another display, show the target desktop, and bring it back.
   - With only one display: carry it, holding the title bar while the desktop switches.
4. **A second run with everything in place changes nothing** and makes no desktop switches.
5. **Failures** go in a small panel at the top of the screen and in `~/Library/Logs/Tile/arrange.txt`, and the run continues with the rest. **Esc** cancels between steps and returns to the starting desktops.

**Carrying a window** needs a point on its title bar that isn't a tab or a button. Tile hit-tests the title bar for one, right of the traffic lights. If carrying grabs the wrong thing in some app (a tab tears off, say), set `"grab": { "<bundle id>": [x, y] }`, in points from the window's top-left. Carrying is only needed when one display is connected.

### Capture

Use **Capture Current Desktops into Arrangement…** in the menu, or `tile://capture?name=work`.

1. Lay out a desktop by hand.
2. Capture it under a name.
3. Swipe each display to its next desktop and capture again under the same name.

Each capture records the desktop showing on every display of the active profile, with every standard window on it. Frames are saved as rects rounded to 0.001, adjusted so the gaps put each window back exactly where it was.

Re-capturing a desktop replaces its old entry, and the rest of the arrangement stays.

**What brings each window back.** A window records `open` when Tile can tell what it shows:

- **Documents:** the file (TextEdit, Preview, Pages, and other apps that report one).
- **VS Code and its forks** (Insiders, VSCodium, Cursor, Windsurf): the workspace folder, so two VS Code windows on two projects come back as those two projects.
- **Terminals:** the working directory, when the app reports it (Terminal) or puts the path in the title. Warp's title is the tab name, so Warp windows are matched by app.

Browsers, Mail and Finder never record `open`: they restore their own windows, and opening a page again would duplicate it.

Without `open`, a title is recorded only when the app has several windows in the capture. A single window's title changes (web pages, channels), and a stale title would stop it matching.

Capture rewrites only the `arrangements` section of the file, in the same layout as above, and leaves the rest of your text alone. The Settings window does the same for `layouts`, `bindings` and `ignoredApps`.

## Settings window

Open it with **Settings…** in the menu, or `tile://settings`. It has three tabs:

- **Bindings.** Click a shortcut to record a new one. Esc cancels the recording, and Delete clears the shortcut, which removes the binding on save. Rows are flagged when they conflict with another binding or another app holds the shortcut. Cycles are edited in the JSON.
- **Layouts.** Edit a rect, or drag across a grid to pick cells. Each layout is previewed on every display of the active profile, in that display's shape, with the gaps applied.
- **Ignored Apps.** Remove apps, or add one from the running apps.

**Save** validates everything together and writes only those sections. Profiles and arrangements stay in the JSON, or come from Capture.

## URL scheme

| URL | Does |
|---|---|
| `tile://apply?layout=<id>` | applies a layout to the focused window |
| `tile://action?name=<restore\|next-display\|previous-display>` | runs an action on the focused window |
| `tile://arrange?id=<id>` | runs an arrangement |
| `tile://capture?name=<id>` | captures the showing desktops into an arrangement |
| `tile://profile?id=<id>` / `tile://profile` | overrides the profile / back to automatic |
| `tile://settings` | opens Settings |
| `tile://selftest` | applies every layout on every display to a TextEdit window and checks each frame. Writes `selftest.txt`. Moves a window, switches no desktops. |
| `tile://debug/arrangetest` | the arranger's selftest: TextEdit documents and Calculator across desktops, run twice to check idempotence. It also adds a desktop (and removes it afterwards) and opens a document onto it. Writes `arrangetest.txt`. **Switches desktops: hands off.** |
| `tile://debug/login` | runs the login arrangement now (the active profile's `onActivate`, launching apps). |
| `tile://debug/windows` | what Capture would record as `open` for each window. Writes `windows.txt`. |
| `tile://debug/missioncontrol` | opens Mission Control and describes the Dock's Accessibility tree. Writes `missioncontrol.txt`. |
| `tile://debug/spaces` | displays, desktops, and which desktop each window is on. Writes `spaces.txt`. |
| `tile://debug/spike` | the original Spaces experiments. Writes `spike.txt`. **Takes over the mouse.** |

Reports go to `~/Library/Logs/Tile/`. Everything is also logged through `os.Logger` under the subsystem `com.epsilonlimited.tile`:

```sh
/usr/bin/log stream --level info --predicate 'subsystem == "com.epsilonlimited.tile"'
```

(In zsh, give the full path: `log` on its own is a shell builtin.)

## How desktops are handled, and what's private

macOS has no public API for Spaces. The spike (`tile://debug/spike`) tested every method on macOS 26.2.

**Reading** uses private SkyLight functions that work with SIP on:

- `SLSCopyManagedDisplaySpaces`: desktops per display
- `SLSManagedDisplayGetCurrentSpace`: the desktop showing
- `SLSCopySpacesForWindows`: which desktop a window is on
- `_AXUIElementGetWindow`: the window id behind an AX element

They're all in `Sources/Tile/Private/SkyLight.swift` and resolved with `dlsym`, so a symbol Apple removes turns into an error, not a crash.

**Writing** through SkyLight (`SLSMoveWindowsToManagedSpace` and the like) does nothing from any process but the Dock, so Tile doesn't. It moves windows the ways listed under Arrangements: Desktop N shortcuts, AX moves across displays, and carrying by the title bar.

**Adding desktops** goes through the Dock's own Accessibility tree while Mission Control is open: `mc` › `mc.display` (with `AXDisplayID`) › `mc.spaces` › `mc.spaces.add`. Each desktop button in `mc.spaces.list` also has an `AXRemoveDesktop` action. See `Sources/Tile/MissionControl.swift`.

## Install with Homebrew

```sh
brew install --cask Epsilon-Limited-Solutions/tap/tile
```

The cask lives in [Epsilon-Limited-Solutions/homebrew-tap](https://github.com/Epsilon-Limited-Solutions/homebrew-tap) and installs a Developer ID-signed, notarized build from this repo's GitHub Releases. `brew upgrade` picks up new releases.

### Cutting a release

1. Put the new version in `VERSION`, commit, tag it `v<version>`, and push the tag.
2. The [Release workflow](.github/workflows/release.yml) builds on a macOS runner, signs with the Developer ID certificate, notarizes and staples, publishes `Tile-<version>.zip` and its sha256 to GitHub Releases, and rewrites `Casks/tile.rb` in the tap with `scripts/cask.sh`.

The workflow needs these repository secrets: `DEVELOPER_ID_P12_BASE64`, `DEVELOPER_ID_P12_PASSWORD`, `APPLE_ID`, `APPLE_TEAM_ID`, `APPLE_APP_PASSWORD`, and `TAP_GITHUB_TOKEN`. The comment at the top of the workflow says what each one is.

To release from this machine instead, with the Developer ID certificate in the keychain and a `tile-notary` notarytool profile:

```sh
./build.sh release && gh release create v$(cat VERSION) dist/Tile-*.zip dist/Tile-*.zip.sha256 --generate-notes
```

then write `scripts/cask.sh <version> <sha256>` into the tap's `Casks/tile.rb`.

**Why Developer ID.** A downloaded zip carries the quarantine flag, and Gatekeeper only opens a quarantined app that's signed with a Developer ID certificate and notarized. The Apple Development certificate `build.sh install` uses works only for builds made on the machine that holds it. `build.sh release` refuses to notarize anything else; `TILE_NOTARIZE=0` builds a local-only zip for testing the packaging.

**Switching builds.** A Developer ID build has a different signature from a local Apple Development build. The first run after switching between them needs Accessibility granted again (or `tccutil reset Accessibility com.epsilonlimited.tile`).

## Layout of the code

- `Sources/TileCore`: pure logic, all unit tested.
  - geometry and coordinate flips
  - the layout engine
  - config parsing, validation and writing back
  - key strings
  - binding resolution
  - profile matching
  - arrangement planning and Capture
- `Sources/Tile`: the AppKit app.
  - AX window moving
  - hotkeys (Carbon `RegisterEventHotKey`)
  - display profiles
  - Spaces
  - the Arranger, Capture, the menu, and Settings (SwiftUI)
- `Tests/TileCoreTests`: `swift test`

## License

Copyright © 2026 Epsilon Limited Solutions LLC.

Tile is free software under the [GNU General Public License, version 3](LICENSE). You can use it, change it and share it, including at work. If you distribute a modified version, it has to ship under the same license with its source.
