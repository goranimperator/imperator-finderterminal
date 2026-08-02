# Vendored SwiftTerm

Upstream: https://github.com/migueldeicaza/SwiftTerm — MIT, see `LICENSE`.
Vendored at **v1.14.0** (`849e8a4f3d6f79ddee07152400137f1370c32621`).

Only `Sources/SwiftTerm` is here, built as a local target from the root
`Package.swift`. The remote SPM dependency is gone: the library needs a patch
that cannot be applied from outside its module.

`Sources/iOS` and `Sources/Documentation.docc` are deleted from the copy: this
app is macOS-only, so the iOS views never compile and the catalogue never
builds. Delete them again after every upstream sync.

## Local patches

### `Sources/Apple/AppleTerminalView.swift` — reverse video swaps, never inverts

`mapColor` used to render `.defaultInvertedColor` as a per-channel inverse of
the theme's colours:

```swift
case .defaultInvertedColor:
    if isFg { return nativeForegroundColor.inverseColor() }
    else    { return nativeBackgroundColor.inverseColor() }
```

Reverse video (SGR 7) means *swap foreground and background*, which is what
Terminal.app and xterm do. Inverting instead turns a green-on-black profile
(`#28FE14`) into magenta (`215, 1, 235`) on white, so zsh's pasted-text
highlight, `less`/`man` status lines, vim's visual selection and fzf's current
line all came out the wrong colour. Explicit colours were already swapped
correctly — only the default-colour case was wrong.

Patched to:

```swift
case .defaultInvertedColor:
    return isFg ? nativeBackgroundColor : nativeForegroundColor
```

Still present upstream as of `main` @ 6918d74 (2026-07-27).

## Updating

1. Clone upstream at the new tag, copy `Sources/SwiftTerm` over `Sources` here,
   then delete `Sources/iOS` and `Sources/Documentation.docc` again.
2. Re-apply every patch above (each is marked `PATCH (imperator-finder-terminal)`
   in the source — grep for it).
3. Update the version and commit recorded at the top of this file.
4. `./build.sh release`, then check reverse video: paste into the terminal and
   confirm the highlight matches Terminal.app (background = text colour,
   text = background colour).
