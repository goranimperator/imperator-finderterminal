# Imperator FinderTerminal

A keyboard-triggered terminal that docks over the frontmost **real** Finder window
(quake-style), the way [sheru.app](https://sheru.app) does `⌘J` — but without replacing Finder.
Finder stays 100% untouched: all native views (icon, list, **column**, **gallery**) keep working,
because the app never modifies Finder. It just overlays a themed terminal on top and keeps the two
in sync.

## Why not a real Finder extension?

macOS exposes **no API to embed a view inside a Finder window**. A Finder extension (`FIFinderSync`)
can only add a toolbar button, a right-click menu, sidebar icons, and file badges — never a panel or
terminal. So the terminal cannot live *inside* Finder. This app is the closest thing that keeps the
real Finder: a background overlay anchored to the frontmost Finder window.

## How it works

- **Background menu-bar app** (`LSUIElement`, no Dock icon). One dependency: [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm).
- **Global hotkey `⌃\`** (Control-backtick) toggles the panel. (Not `⌘J` — that is Finder's own
  "Show View Options"; a global hotkey would swallow it.)
- On open it reads the frontmost Finder folder (Apple events) and docks a SwiftTerm zsh over that
  window (Accessibility gives the window frame + move/resize tracking). No Finder window → drops from
  the top of the screen, `cd ~`.
- **Theme** is pulled from your **Terminal.app default profile** (background, text, cursor, selection,
  16 ANSI colors, font).
- **Two-way sync**: navigating in Finder `cd`s the shell; `cd` in the shell moves Finder. This works
  because the shell is spawned with `TERM_PROGRAM=Apple_Terminal`, so the system `/etc/zshrc` emits
  OSC 7 on every prompt, which SwiftTerm reports back. A single shared "current directory" value
  breaks the feedback loop.

## Build

```
./build.sh          # debug build -> "build/Imperator FinderTerminal.app", codesigned "Imperator Dev"
./build.sh release  # optimized
```

Requires the Swift toolchain (Command Line Tools is enough; full Xcode not required to build).
Override the signing identity with `CODESIGN_IDENTITY=... ./build.sh`.

## First run

```
open "build/Imperator FinderTerminal.app"
```

Grant two permissions (the app degrades gracefully until you do):

1. **Accessibility** — System Settings ▸ Privacy & Security ▸ Accessibility ▸ enable *Imperator FinderTerminal*.
   Needed to dock onto and follow the Finder window. Without it you get the top-of-screen quake
   fallback.
2. **Automation ▸ Finder** — prompted the first time you press the hotkey. Needed to read/drive the
   Finder folder.

Then: open a Finder window, press **⌃\`**.

## Test checklist

1. Finder in **column view**, open a folder, press ⌃\` → terminal docks over the window, `pwd`
   matches the folder. Switch Finder to **gallery view** → still fine (Finder is untouched).
2. Set Terminal.app's default profile to a dark one (e.g. "Pro"), relaunch the app, open the panel →
   colors + font match.
3. In the panel run `cd ~/Downloads` → Finder navigates there. Click a different folder in Finder →
   the prompt `cd`s there. No flicker/loop.
4. Toggle ⌃\` a few times → same session persists, repositions to the current Finder window.
5. Move/resize the Finder window while the panel is open → the panel follows.

Rebuilt the app? Quit the running one first (menu-bar icon ▸ Quit), then relaunch.

## Not in v1 (see plan)

Rebindable hotkey + preferences UI, live theme reload, an optional `FIFinderSync` toolbar button /
"Open terminal here" contextual item, multi-window / per-window sessions, panel size memory.

## Known limits

- **Multi-monitor**: the AX→Cocoa coordinate flip uses the menu-bar screen height; docking may be off
  on secondary displays. Single-display is exact.
- **Non-zsh shells**: OSC 7 (terminal→Finder) relies on the system zsh wiring; bash/fish won't emit
  it, so only Finder→terminal will sync there. Finder→terminal always works.
- Non-sandboxed dev build (needs PTY spawn + Apple events + Accessibility); not for the App Store.
