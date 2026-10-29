# Build "Tile": a personal macOS window manager

## Goal

A native macOS menu-bar app that does four things:

1. **Snaps windows** into layouts I define, using shortcuts I define.
2. **Knows my display setups.** Laptop-only versus docked are separate profiles, and
   shortcuts can behave differently per display (a vertical monitor wants top/bottom,
   not left/right).
3. **Runs arrangements.** One hotkey launches my usual apps and puts each one at the
   right place, on the right screen, on the right **native macOS desktop (Space)**.
   Then I can 4-finger-swipe between desktops and everything is already there.
4. **Captures arrangements.** I lay windows out by hand and save them, instead of
   writing coordinates in JSON.

It's for my own use. No App Store, no sandbox, no polish. It has to work reliably on
this machine. Homebrew distribution comes later, so structure the build for it, but
don't build the tap now.

- Working directory: `/Users/thomasduquemin/epsilon/applications/mosaic-clone`
- App name `Tile`, bundle id `com.epsilonlimited.tile`
- Run `git init` first, then commit after each build step that works.

## This machine

- macOS 26.2, Apple M3 Pro, Xcode 26.6 at `/Applications/Xcode.app`, Homebrew installed.
  XcodeGen and Tuist are not installed.
- Displays when docked (laptop-only is the built-in alone):
  - built-in "Built-in Retina Display", 1512×982 points, primary
  - role `vertical-left`: DELL S2722QC, rotated 270°, left of the laptop, 1440×2560
    points, serial 810894658
  - role `vertical-right`: DELL S2722QC, rotated 90°, right of the laptop, 1440×2560
    points, serial 825446978
  - The two Dells share a name (macOS appends "(1)"/"(2)", which can swap), so
    profiles must match them by serial.
- Signing identity: `Apple Development: Thomas Duquemin (3367SAF32Q)`, the only one
  installed. There's no Developer ID certificate yet.

## Build setup

- **Swift Package Manager**: one executable target plus a test target. Deployment
  target macOS 15. Swift 5 language mode. Mark UI, AX, and event code `@MainActor`.
  Don't spend time fighting strict concurrency.
- `build.sh` with subcommands:
  - `./build.sh install`:
    1. `swift build -c release`
    2. assemble `Tile.app` (`Info.plist` with `LSUIElement=true`, the bundle id,
       a version, and the `tile://` URL scheme)
    3. codesign it with the Apple Development identity above
    4. copy it to `~/Applications/Tile.app`
    5. kill the running instance and relaunch
  - `./build.sh test`: runs `swift test`
  - `./build.sh release`: same as `install`, but writes `dist/Tile-<version>.zip` plus
    a sha256 instead of installing. This is what a Homebrew cask will consume later.
- **Never ad-hoc sign.** macOS ties the Accessibility grant to the code signature.
  An ad-hoc signature changes on every build, which would mean re-granting permission
  after every rebuild. If the grant gets stuck:
  `tccutil reset Accessibility com.epsilonlimited.tile`.
- No third-party dependencies unless one saves real effort. The JSON config file is
  the source of truth.

## Architecture

AppKit `NSApplication` with an `NSStatusItem`. SwiftUI only for the settings window.
No Dock icon.

| Component | Responsibility |
|---|---|
| `ScreenGeometry` | Convert between NSScreen and AX coordinates, look up `visibleFrame`, find the screen a window is on. Pure functions, unit-tested. |
| `LayoutEngine` | `(layout, visibleFrame, gaps) -> CGRect`. Pure, unit-tested. |
| `DisplayProfiles` | Match connected displays to profiles and assign role names. Re-evaluate on `NSApplication.didChangeScreenParametersNotification`. |
| `WindowMover` | AX: find the focused window, read its frame, set its frame, read the result back. |
| `Spaces` | All Space and desktop logic: list desktops per display, read the active desktop, find which desktop a window is on, switch desktops, move a window to a desktop. **The only place private APIs are allowed.** Private symbols go in `Private/SkyLight.swift`, resolved with `dlsym`, so a missing symbol degrades to an error instead of a crash. |
| `Arranger` | Runs an arrangement as an ordered, cancellable sequence of steps built on `Spaces`, `WindowMover`, and app launching. |
| `Capture` | Snapshots the current desktop on each display into arrangement JSON. |
| `HotkeyManager` | Carbon `RegisterEventHotKey`. Register each unique key combo **once** and resolve which binding applies at press time (see bindings). Reference: `/Users/thomasduquemin/epsilon/applications/momentum/app/Momentum/Utilities/GlobalHotkeyManager.swift`, which handles a single hotkey; generalize it. |
| `ConfigStore` | JSON at `~/.config/tile/config.json`. Writes defaults on first launch, watches the file, and hot-reloads. Validation errors say which line or key is wrong and why. On a bad config, keep the last good one and show the error in the menu. Never crash. |
| `HistoryStore` | Remembers each window's frame before Tile last touched it, so "restore" works. In memory. |

## Features

### 1. Snapping (core)

- **Accessibility permission.** On launch, call `AXIsProcessTrustedWithOptions` with
  the prompt option. If not trusted, open the Accessibility settings pane and poll
  until the grant arrives. No relaunch. The menu shows the status.
- **Built-in layouts** in the default config, all editable:
  - left, right, top, and bottom half
  - the four quarters
  - left, center, and right third, plus left and right two-thirds
  - the same thirds and two-thirds running top to bottom, for portrait screens
  - `full`, `almost-full` (centered, 90%), `center` (keep the current size)
- **Custom layouts** in two forms:
  - `"rect": [x, y, w, h]` as fractions (0–1) of the visible frame, origin top-left
  - `"grid": [cols, rows], "cells": [col, row, colSpan, rowSpan]`
- **Bindings** map a shortcut to exactly one of:
  - `"layout": "<id>"`
  - `"cycle": ["<id>", ...]`: repeated presses step through the list. Advance only if
    the window's frame still matches the frame this binding last applied (within a few
    points). Otherwise start at the first entry.
  - `"action": "<name>"`: `restore`, `next-display`, or `previous-display`
  - `"arrange": "<arrangement id>"`
- **Context-dependent bindings.** A binding can include
  `"when": { "profile": "...", "display": "<role>", "orientation": "portrait|landscape" }`.
  - Several bindings may share the same keys.
  - At press time, resolve against the focused window's display and the active
    profile. The most specific match wins, in this order: display role, then
    orientation, then profile, then no `when`.
  - Validation rejects two bindings with the same keys and equal specificity.
- **Multi-display.** `next-display` and `previous-display` keep the window's relative
  frame, mapped proportionally onto the target's visible frame.
- **Gaps.** `outer` and `inner` in points, default 0. The inner gap applies only to
  edges that face another region.
- **Ignore list.** Bundle ids Tile never touches.

### 2. Display profiles

A profile names the displays it expects and gives each one a role:

- **Matchers:** `builtin: true` (`CGDisplayIsBuiltin`), `name` (`NSScreen.localizedName`),
  and optionally `serial` (`CGDisplaySerialNumber`) to tell two identical monitors
  apart, plus `rotation`.
- **Matching:** a profile matches when every role matches a distinct connected display
  and the display counts are equal. The first match wins. The menu offers a manual
  override.
- **`onActivate`** (optional, default off): an arrangement id to run automatically
  when the profile becomes active, for example when I dock.
- **Menu item** "Copy current displays as profile JSON": puts a ready-to-paste profile
  skeleton for the connected displays on the clipboard.

### 3. Arrangements across desktops (the hard part)

An arrangement belongs to one profile. It's a list of `{display role, desktop index}`
targets, each with a list of window placements:

- `app`: bundle id
- `title` (optional): a regex, to pick a specific window when an app has several
- `layout`: a layout id
- `open` (optional): a list of paths or URLs to open with the app, such as a project
  folder for the editor

`desktop` is a 1-based index within that display's desktops, in Mission Control order.

**Required behavior:**

- **Validate first.** If a display role is missing, or a display has fewer desktops
  than the arrangement needs, abort before touching anything. Say exactly what to fix,
  for example: "vertical needs 3 desktops, has 2: add one in Mission Control". Tile
  doesn't create desktops.
- **Launch missing apps.** For each app that isn't running, switch to its target
  desktop first, then launch it, so its first window opens there. Wait for the window
  with an `AXObserver` (`kAXWindowCreatedNotification`), timeout ~15s, because Slack
  is slow.
- **Move windows that are already open** to their target desktop and display, then
  apply the layout.
- **Idempotent.** If everything is already in place, a second run makes no visible
  desktop switches. Check each window's current Space first.
- **Finish cleanly.** Leave each display on the desktop listed in `endOn`. If there's
  no `endOn`, return to the desktops that were active at the start.
- **Cancellable.** Show a small HUD ("Arranging work… Esc to cancel"). Esc aborts
  cleanly between steps.
- **Report.** When a placement fails, log it and show it in the HUD, then continue
  with the rest. Don't abort the whole run.

**Capture.** Add a menu item and a URL action: "Capture current desktops into
arrangement…".

1. Ask for an arrangement name (an `NSAlert` with a text field is fine).
2. For each display, record the active desktop index and every standard window visible
   on it: bundle id, title, and frame as a fractional `rect` of the visible frame,
   rounded to 0.001.
3. Merge into the config by `(display, desktop)` and write the file back.

The workflow is: arrange by hand, capture, swipe to the next desktop, capture again.

### 4. Menu bar menu

- the layouts (clicking one applies it to the frontmost app's focused window)
- the arrangements
- the active profile, with a manual override submenu
- Capture current desktops…
- Copy current displays as profile JSON
- Settings…
- Open Config File
- Reload Config
- Launch at Login (`SMAppService.mainApp`)
- status lines for:
  - Accessibility
  - the macOS settings checks (see pitfalls)
  - the last config error
- Quit

### 5. Settings window (ugly is fine)

- **Bindings table** with a shortcut recorder: a local `NSEvent` keyDown monitor while
  recording. Esc cancels and Delete clears. Show the `when` scope.
- **Conflict detection.** Flag duplicates at the same specificity. When
  `RegisterEventHotKey` fails, mark the binding "unavailable (taken by system/another
  app)".
- **Layout editor.** Name, id, and either the rect fields or a clickable N×M grid
  where you drag to select cells. Show a preview in the aspect ratio of each display in
  the active profile.
- Profiles and arrangements are edited as JSON or through Capture. No UI for them.

### 6. URL scheme (automation hook and test harness)

- `tile://apply?layout=<id>`
- `tile://action?name=<name>`
- `tile://arrange?id=<id>`
- `tile://capture?name=<id>`
- `tile://selftest`: opens a TextEdit document, applies every layout on every connected
  display, reads back each frame, and writes a pass/fail report to
  `~/Library/Logs/Tile/selftest.txt`
- `tile://debug/spaces`: dumps displays, desktops, the active desktop per display, and
  which desktop each on-screen window is on, to `~/Library/Logs/Tile/spaces.txt`

Log everything through `os.Logger` with subsystem `com.epsilonlimited.tile`.

### Key strings

Shortcuts are written as strings like `"ctrl+opt+left"` or `"hyper+w"`. `hyper` means
ctrl+opt+cmd+shift.

- Keys: letters, digits, arrows, `return`, `space`, `tab`, `escape`, `delete`,
  `f1`–`f20`, and punctuation
- Map them to `kVK_*` codes and assume a US layout.
- Parse and format in both directions.
- Reject bindings whose only modifiers are opt or opt+shift, because macOS 15+ refuses
  those for `RegisterEventHotKey`. Say so in the error.

## Moving windows between Spaces: read before designing `Spaces`

There is **no public API** for switching Spaces or moving windows between them.
Constraints:

- **Do not** use anything that requires disabling SIP (for example, yabai's scripting
  addition). This machine holds client credentials. If no SIP-safe method works,
  stop and tell me.
- **Do not** emulate workspaces by hiding windows off-screen, the way AeroSpace does.
  I want native desktops so the 4-finger swipe works.
- Reading is fine through private SkyLight/CGS functions that work without SIP:
  - `CGSMainConnectionID`
  - `CGSCopyManagedDisplaySpaces` (desktops per display, in order)
  - `CGSManagedDisplayGetCurrentSpace`
  - `CGSCopySpacesForWindows`
  - `_AXUIElementGetWindow` (AX element to `CGWindowID`)

**Spike these before writing `Arranger`, and report which ones work on macOS 26.2,
with evidence from `tile://debug/spaces`:**

1. **Switch desktop.** Post the system "Switch to Desktop N" shortcut (ctrl+N) with
   `CGEvent`. Then poll the active Space until it changes, with a timeout. No fixed
   sleeps. Work out empirically how the system's Desktop N numbering maps onto
   per-display desktop indices when "Displays have separate Spaces" is on, and record
   the mapping.
2. **Move a window to another desktop on the same display.** Try these in order:
   - (a) `CGSMoveWindowsToManagedSpace`. It's probably blocked for non-Dock processes
     since macOS 14.5, but it's 10 lines to try.
   - (b) **Grab and switch**: post a mouse-down on a draggable point of the window's
     title bar, switch desktops with ctrl+N, post the mouse-up. The window rides along.
     - Always post the mouse-up and restore the cursor position in a `defer`. A stuck
       mouse button is the worst possible failure mode.
     - Choose the grab point carefully. On Chrome, a mouse-down on a tab tears the tab
       off. Use a default offset from the window's top-left, plus a per-app `grab`
       override in the config, and test it on VS Code, Slack, Chrome, and iTerm.
3. **Move a window to a desktop on another display.** Hypothesis: first make the target
   desktop active on the target display, then set the window's position onto that
   display through AX. The window should land on that display's active desktop with no
   grab needed. Verify it.
4. **Find windows on other desktops.** AX only lists windows on currently visible
   Spaces. Use `CGWindowListCopyWindowInfo(.optionAll)` plus `CGSCopySpacesForWindows`
   to find a window's desktop, switch there, then get its AX element.

**After the spike, stop and report** what works, what doesn't, and the design you'll
build on. Then build `Arranger`.

## Known pitfalls: handle each one explicitly

1. **Coordinates.** AX coordinates have their origin at the top-left of the *primary*
   display (`NSScreen.screens[0]`), and y grows downward. NSScreen coordinates have a
   bottom-left origin.
   - Convert with `axY = NSScreen.screens[0].frame.maxY - rect.maxY`.
   - Keep the conversion in one function, unit-tested against fixtures that include a
     portrait display taller than the primary, displays left, right, above, and below,
     and negative origins.
2. Use `visibleFrame`, not `frame`.
3. **Setting a frame.** Set the size, then the position, then the size again. Read the
   frame back. Accept small misses from apps with minimum sizes or character-cell
   sizing (terminals), and make selftest tolerate them.
4. **Electron and Chromium apps.** Turn off `AXEnhancedUserInterface` on the app
   element while moving, then restore it. Otherwise resizes animate and land in the
   wrong place.
5. **Focused window.** Use `kAXFocusedWindowAttribute`, falling back to
   `kAXMainWindowAttribute`. Skip fullscreen windows (each one is its own Space),
   sheets, and non-standard subroles. Beep when there's nothing to act on.
6. `AXUIElementSetMessagingTimeout` of about 0.5s, so a hung app can't freeze Tile.
7. **Hotkeys.** Use Carbon `RegisterEventHotKey`, not a `CGEventTap`, so no Input
   Monitoring permission is needed. Unregister everything and re-register on reload.
8. **macOS settings that arrangements depend on.** Check these at launch and show any
   failure in the menu, with the exact fix:
   - "Automatically rearrange Spaces based on most recent use" must be **off**
     (`defaults read com.apple.dock mru-spaces` must be `0`). Otherwise desktop indices
     shuffle and every arrangement breaks.
   - "Displays have separate Spaces" must be **on** (`com.apple.spaces spans-displays`
     is absent or `0`).
   - The "Switch to Desktop N" shortcuts must be enabled under System Settings >
     Keyboard > Keyboard Shortcuts > Mission Control. Read
     `com.apple.symbolichotkeys` (ids 118+) to verify.
   - Apps pinned to a desktop through Dock > Options > Assign To will fight Tile. Detect
     them if feasible, and warn.
9. **Space switch animation.** Detect the switch by polling the active Space. Mention
   in the README that turning on "Reduce motion" makes switches much faster.
10. Do AX and event posting on the main thread.

## Example config (the shape, with this machine's displays)

Bundle ids are examples. I'll edit them.

```json
{
  "gaps": { "outer": 0, "inner": 0 },
  "ignoredApps": [],
  "profiles": [
    { "id": "laptop", "displays": { "laptop": { "builtin": true } } },
    { "id": "desk",   "displays": {
        "laptop":         { "builtin": true },
        "vertical-left":  { "name": "DELL S2722QC", "serial": 810894658 },
        "vertical-right": { "name": "DELL S2722QC", "serial": 825446978 } },
      "onActivate": null }
  ],
  "layouts": [
    { "id": "left-half",    "name": "Left Half",      "rect": [0, 0, 0.5, 1] },
    { "id": "top-half",     "name": "Top Half",       "rect": [0, 0, 1, 0.5] },
    { "id": "bottom-half",  "name": "Bottom Half",    "rect": [0, 0.5, 1, 0.5] },
    { "id": "top-60",       "name": "Top 60%",        "rect": [0, 0, 1, 0.6] },
    { "id": "bottom-40",    "name": "Bottom 40%",     "rect": [0, 0.6, 1, 0.4] },
    { "id": "main-sidebar", "name": "Main + Sidebar", "grid": [6, 4], "cells": [0, 0, 4, 4] }
  ],
  "bindings": [
    { "keys": "ctrl+opt+left",  "cycle": ["left-half", "left-third", "left-two-thirds"] },
    { "keys": "ctrl+opt+left",  "when": { "orientation": "portrait" },
      "cycle": ["top-half", "top-third", "top-two-thirds"] },
    { "keys": "ctrl+opt+return",    "layout": "full" },
    { "keys": "ctrl+opt+backspace", "action": "restore" },
    { "keys": "ctrl+opt+cmd+right", "action": "next-display" },
    { "keys": "hyper+w",            "arrange": "work" }
  ],
  "arrangements": [
    { "id": "work", "profile": "desk",
      "endOn": { "vertical-left": 1, "vertical-right": 1, "laptop": 1 },
      "desktops": [
        { "display": "vertical-right", "desktop": 1, "windows": [
          { "app": "com.microsoft.VSCode",  "layout": "top-60", "open": ["~/epsilon"] },
          { "app": "com.googlecode.iterm2", "layout": "bottom-40" } ] },
        { "display": "vertical-right", "desktop": 2, "windows": [
          { "app": "com.tinyspeck.slackmacgap", "layout": "top-half" },
          { "app": "com.apple.iCal",            "layout": "bottom-half" } ] },
        { "display": "laptop", "desktop": 1, "windows": [
          { "app": "com.google.Chrome", "layout": "full" } ] }
      ] }
  ]
}
```

## Build order

1. **Skeleton.** Package, `build.sh`, menu bar item, Accessibility flow, URL scheme
   router, logging, `tile://debug/spaces`. **Stop and tell me to grant
   Accessibility.**
2. **Spaces spike.** Run the experiments in the spike section above. **Stop and report.**
3. **Pure logic.** `ScreenGeometry`, `LayoutEngine`, config parsing and validation,
   key-string parsing, binding resolution, profile matching. Cover it all with
   `swift test`, and test hard: these are pure functions.
4. **`WindowMover` + `tile://selftest`.** Iterate until selftest passes on both
   displays.
5. **Hotkeys and hot reload.** Tell me which keys to press and what should happen. You
   can't press global hotkeys yourself.
6. **Display profiles.** Live switching on connect and disconnect, plus the manual
   override.
7. **`Arranger` and `Capture`.** Use whatever method won the spike. Verify with
   `tile://arrange` and `tile://debug/spaces` before and after a run, and test a second
   run for idempotence.
8. **Menu, settings window, Launch at Login, ignore list.**
9. **README.** How to build, where the config lives, the URL scheme, the required
   macOS settings, how to reset TCC, and the Homebrew plan below.

## Later (don't build now): Homebrew

The plan:

- a personal tap `Epsilon-Limited-Solutions/homebrew-tap`
- `Casks/tile.rb` pointing at the GitHub release zip from `./build.sh release`

Downloaded builds carry the quarantine flag, so they'll need a **Developer ID
Application** certificate plus notarization (`xcrun notarytool`). The Apple
Development certificate only works for builds made on this machine. In the README,
note what `build.sh release` would need to change.

## Optional, ask before building

- Drag-to-snap overlay: hold a modifier while dragging a window to get a grid overlay.
  Check for conflicts with the macOS "Drag windows to screen edges to tile" setting.
- Tile all visible windows of the current app or desktop into a grid.
- An undo stack beyond a single restore.

## Non-goals

App Store, sandboxing, auto-update, localization, onboarding, an app icon beyond an SF
Symbol, analytics, creating or deleting desktops programmatically, and anything that
needs SIP disabled.

## Working style

- Don't ask me things you can settle by reading Apple's docs, the code, or running an
  experiment.
- Do stop at the marked checkpoints.
- No speculative abstractions or protocols with a single implementation.
- When something fails, show me the actual error output, not a summary of it.
