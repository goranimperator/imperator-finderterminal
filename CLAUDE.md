# CLAUDE.md

Guidance for Claude Code (claude.ai/code) when working in this repository.

## Build & Run

```bash
make install                  # Release build, kill old process, install to /Applications, launch
make                          # Debug build into build/
make clean                    # Remove build/ and .build/
make dist VERSION=x.y.z       # Build + zip to dist/ -- no git or remote writes
make release VERSION=x.y.z    # Bump Info.plist, commit, tag, push, publish GitHub release
```

Everything routes through `build.sh`: SwiftPM compile, bundle assembly, codesign. Use
`make install` after code changes — it kills the running copy first, which is required, because a
stale process keeps the old event tap alive.

`make release` needs `gh` and a clean working tree. Tags are plain semver (`v1.0.0`); the app name
lives in the release title. `CFBundleVersion` is the commit count INCLUDING the release commit —
`git rev-list --count HEAD` plus one, since that commit does not exist yet when the target stamps
the number. `RELEASE_BUILD_NUMBER` in the Makefile is the value, not `BUILD_NUMBER`.

## Signing

`build.sh` signs with the local self-signed `Imperator Dev` identity (override with
`CODESIGN_IDENTITY=...`). Released builds use the same identity on purpose: the designated
requirement pins that certificate rather than the binary hash, so the Accessibility, Automation and
Input Monitoring grants survive an update. Ad-hoc signing would reset all three on every version.
The app is not notarized, so Gatekeeper blocks the first launch on any machine either way.

## Architecture

Background menu-bar app (`LSUIElement`), AppKit with SwiftUI for the popover, Settings and About.
One terminal per Finder window, keyed by `CGWindowID`.

| File | Role |
|------|------|
| `AppDelegate.swift` | Menu bar item, hotkey, terminal registry, settings fan-out, quake fallback |
| `DockedTerminal.swift` | One Finder window and its terminal: docking, following, resizing, teardown |
| `WindowTracker.swift` | Accessibility reads/writes plus `AXObserver` notifications |
| `TerminalPanel.swift` | The terminal window: geometry, fades, key equivalents, sheets |
| `TerminalSession.swift` | SwiftTerm view, shell process, OSC 7 folder sync |
| `SpaceReservation.swift` | Private SkyLight calls, the only way to free room in a fullscreen space |
| `CloseGuard.swift` | CGEventTap for ⌘W, the close button and minimize starts |
| `FinderBridge.swift` | Apple events to and from Finder |
| `TerminalTheme.swift` | Terminal.app profile decoding and the bundled presets |
| `PopoverView.swift`, `SettingsView.swift`, `Settings.swift` | Popover, Settings window, About, `@AppStorage` |
| `Vendor/SwiftTerm/` | Vendored terminal emulator with one local patch — see its README |

Key constraints learned the hard way, do not undo them:

- Accessibility position/size writes are dropped inside a native fullscreen space. Room is made with
  `SLSSpaceSetEdgeReservation`, and the inset must be **whole points** — a fractional value collapses
  the space.
- Fullscreen transitions emit a false "window destroyed" notification. Verify with
  `WindowTracker.exists` before tearing a terminal down.
- The panel follows from a `CADisplayLink` that pauses when idle. Drags are coalesced to one apply
  per frame.
- `LSUIElement` apps have no menu bar, so ⌘C/⌘V/⌘X/⌘A are routed in `performKeyEquivalent`.

## Debug tooling

`DevRemote` (distributed notifications: `toggle`, `snapshot`, `exec`, `probe`), `devProbe`,
`devSnapshot` and `devLog` are wrapped in `#if DEBUG` and do not exist in a release build. Keep it
that way: `exec` types into the user's shell, and this app holds Accessibility, Automation and Input
Monitoring grants that a caller would otherwise borrow for free. Headless verification therefore
runs against a debug build.

## Brand Guidelines

Follows the Imperator Apps BrandBook (`github.com/goranimperator/imperator-apps-brandbook`):

- Brand color `#A01818` (`AppColors.brand`)
- Dark mode forced: `NSApp.appearance = NSAppearance(named: .darkAqua)`
- Accent override: `UserDefaults.standard.set(0, forKey: "AppleAccentColor")`
- Bundle ID `com.goranimperator.ImperatorFinderTerminal`
- About panel keeps `© 1986-<year> Goran Imperator`; `NSHumanReadableCopyright` in `Info.plist`
  matches the MIT LICENSE instead. The two differ on purpose.
- English everywhere user-facing: UI text, README, release notes, tag messages, commit messages

## Git

- `origin` -> `git@github.com:goranimperator/imperator-finderterminal.git` (the GitHub slug has no
  hyphen before "terminal", the local directory does — GitHub's name wins)
- Never commit or push without Goran saying so in that message
