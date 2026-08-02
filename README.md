<p align="center">
  <img src="Resources/icon.png" width="128" height="128" alt="Imperator FinderTerminal">
</p>

# Imperator FinderTerminal

A keyboard-triggered terminal that docks onto the frontmost **real** Finder window, the way
[sheru.app](https://sheru.app) does `⌘J` — but without replacing Finder. Finder stays untouched, so
every native view keeps working (icon, list, **column**, **gallery**). The app shrinks the Finder
window, attaches a themed terminal in the freed space, and keeps the two pointed at the same folder.

## Requirements

Requires macOS 14 or later, Apple silicon. Built and tested on macOS 26 only — older versions are
expected to work but have not been verified.

Install at your own risk. The app is not notarized and carries no Apple Developer signature, so
macOS cannot vouch for it. It is provided as is, with no warranty, under the MIT license.

## Install

Download the latest zip from
[Releases](https://github.com/goranimperator/imperator-finderterminal/releases), unzip, and move
`Imperator FinderTerminal.app` to `/Applications`.

The app is signed with a self-signed certificate and is not notarized, so Gatekeeper blocks the
first launch. Right-click the app and choose **Open**, or clear the quarantine flag:

```bash
xattr -dr com.apple.quarantine "/Applications/Imperator FinderTerminal.app"
```

There is no Dock icon. The app lives in the menu bar.

## Permissions

Three grants in **System Settings ▸ Privacy & Security**. The app starts without them and degrades
instead of failing, but the docking only works once Accessibility is on.

| Permission | What breaks without it |
|---|---|
| **Accessibility** | No docking. The terminal falls back to a quake panel at the top of the screen, and the Finder window is never moved, resized or followed. |
| **Automation ▸ Finder** | No folder sync in either direction. Prompted the first time you press the hotkey. |
| **Input Monitoring** | No warning before a close. `⌘W` and the red close button are intercepted so the terminal can ask before it goes away; without the grant the interception never fires. |

Accessibility and Input Monitoring have to be ticked by hand — macOS shows no prompt for them.

## Use

Open a Finder window and press **`⌘⌥§`** (section key, top-left on an ISO keyboard). The Finder
window shrinks and the terminal takes the freed strip, opened in the folder Finder is showing. Press
the hotkey again to close it and give Finder its size back. With no Finder window open, the app
opens one and docks to it.

- **Two-way folder sync.** Click into another folder in Finder and the shell follows. `cd` in the
  shell and Finder follows.
- **Resize.** Drag the pill in the gap to resize both windows at once. Drag the terminal's outer
  edge to resize only the terminal.
- **Fullscreen.** A Finder window in native fullscreen docks the same way as a normal one.
- **Copy and paste.** `⌘C`, `⌘V`, `⌘X`, `⌘A` work inside the terminal.
- **Minimize.** Minimizing the Finder window fades the terminal out with the Dock animation, and
  brings it back on restore.
- **Closing.** Closing a Finder window that has a terminal attached asks first. Cancel keeps the
  window and the folder.

Everything else lives behind the menu bar icon: theme, custom themes, keyboard shortcut, font size,
dock side (top / right / bottom / left), which window keeps focus when the terminal opens, and
whether the close warning always shows or only when a process is running.

## Theme

By default the terminal reads your **Terminal.app default profile**: background, text, cursor and
selection colors, all 16 ANSI colors, font and line spacing. Ten classic Terminal.app presets ship
with the app, and colors plus font size can be set by hand in Settings.

## Why not a real Finder extension?

macOS exposes **no API to embed a view inside a Finder window**. A Finder extension (`FIFinderSync`)
can only add a toolbar button, a right-click menu, sidebar icons and file badges — never a panel or
a terminal. So the terminal cannot live *inside* Finder. This app is the closest thing that keeps
the real Finder: a separate window, anchored to the Finder window and moved with it.

## How it works

- **Background menu-bar app** (`LSUIElement`, no Dock icon). No external package dependencies;
  [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) is vendored in `Vendor/`.
- The frontmost Finder folder is read over Apple events. Position, size and fullscreen state are
  read and written over the Accessibility API, and an `AXObserver` reports moves, resizes,
  minimize, fullscreen transitions and closes.
- The panel follows the Finder window from a `CADisplayLink`, one apply per frame, and pauses when
  nothing moves. It hides whenever neither Finder nor the terminal is frontmost, and the Finder
  window's original size is restored when the terminal closes.
- **Fullscreen** is the one case where Accessibility writes are dropped by the system. Room is made
  with a private SkyLight call (`SLSSpaceSetEdgeReservation`) that reserves a strip of the fullscreen
  space. Every symbol is resolved at runtime, so a macOS release that removes it degrades to "no
  fullscreen docking" instead of crashing.
- **Folder sync** works because the shell is spawned with `TERM_PROGRAM=Apple_Terminal`, so the
  system `/etc/zshrc` emits OSC 7 on every prompt and SwiftTerm reports it back. One shared
  "current directory" value breaks the feedback loop.

## Build

```bash
make install
```

Builds release, kills the running copy, installs to `/Applications` and launches. Other targets:

```bash
make
```

```bash
make clean
```

`make` and `make install` both call `./build.sh`, which compiles with SwiftPM, assembles the bundle
and codesigns it with the local `Imperator Dev` identity so macOS keeps the permission grants across
rebuilds. Override with `CODESIGN_IDENTITY=... ./build.sh`. The Swift toolchain from the Command
Line Tools is enough; full Xcode is not needed.

## Release

Build a distributable zip without touching git or the remote:

```bash
make dist VERSION=1.0.0
```

Cut a full release — bumps `Info.plist`, commits, tags `v1.0.0`, pushes, and publishes a GitHub
release with the zip attached:

```bash
make release VERSION=1.0.0
```

Requires the [GitHub CLI](https://cli.github.com) (`brew install gh`, then `gh auth login`) and a
clean working tree. Tags are plain semver; the app name lives in the release title. `CFBundleVersion`
comes from the commit count. Released builds carry the same `Imperator Dev` signature as local ones,
so the permission grants survive an update.

## Layout

| Path | Role |
|---|---|
| `Sources/FinderTerminal/AppDelegate.swift` | Menu bar item, hotkey, per-window terminals, settings fan-out |
| `Sources/FinderTerminal/DockedTerminal.swift` | One Finder window plus its terminal: docking, following, resizing, teardown |
| `Sources/FinderTerminal/WindowTracker.swift` | Accessibility reads and writes, window notifications |
| `Sources/FinderTerminal/TerminalPanel.swift` | The terminal window: geometry, fades, key equivalents |
| `Sources/FinderTerminal/TerminalSession.swift` | SwiftTerm view, shell process, folder sync |
| `Sources/FinderTerminal/SpaceReservation.swift` | Private SkyLight calls for fullscreen spaces |
| `Sources/FinderTerminal/CloseGuard.swift` | Event tap for `⌘W`, close button and minimize |
| `Sources/FinderTerminal/FinderBridge.swift` | Apple events to and from Finder |
| `Sources/FinderTerminal/TerminalTheme.swift` | Terminal.app profile decoding and presets |
| `Sources/FinderTerminal/PopoverView.swift`, `SettingsView.swift` | Menu bar popover, Settings window, About |
| `Vendor/SwiftTerm/` | Vendored terminal emulator, patched (see its README) |

## Known limits

- **Multi-monitor.** The Accessibility-to-Cocoa coordinate flip uses the menu bar screen's height,
  so docking can be off on secondary displays. Single display is exact.
- **Non-zsh shells.** OSC 7 comes from the system zsh wiring, so bash and fish do not emit it and
  only the Finder-to-terminal direction syncs.
- **Mission Control** shows the Finder window and the terminal as two separate windows. Picking
  either raises both, but they cannot be grouped into one.
- **Private API.** Fullscreen docking depends on SkyLight and may stop working on a future macOS.
  Everything else uses public API.
- Not sandboxed, so not App Store material. It needs to spawn a PTY, send Apple events and use the
  Accessibility API.

## Not yet built

An optional `FIFinderSync` toolbar button and "Open terminal here" contextual item, multi-window
sessions per Finder window, panel size memory.

## Third-party

[SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) by Miguel de Icaza, MIT licensed, vendored in
`Vendor/SwiftTerm` at v1.14.0 with one local patch. The patch and the steps to move to a newer
upstream release are documented in [`Vendor/SwiftTerm/README.md`](Vendor/SwiftTerm/README.md); the
upstream license is kept at [`Vendor/SwiftTerm/LICENSE`](Vendor/SwiftTerm/LICENSE).

## License

[MIT](LICENSE) &copy; Goran Imperator
