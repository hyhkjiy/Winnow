# Winnow

Winnow is a Swift + AppKit macOS window searcher under active development.

The current implementation deliberately focuses on architectural boundaries:

- an `LSUIElement` menu-bar application shell;
- a native Carbon global hot key;
- Accessibility permission checking and prompting;
- one synchronized `NSPanel` per screen with a single input owner;
- privacy-safe logging and in-memory-only window models;
- Accessibility-backed window discovery and activation running on a dedicated
  background queue.

The menu-bar `Debug Windows` submenu exposes the current AX validation loop
without involving the search UI: open it to enumerate eligible windows, then
select a row to restore and focus that exact window. MRU ordering and pinyin
matching remain behind explicit interfaces for later implementation slices.

## Requirements

- macOS 14 or later
- Xcode 16 or later
- Swift 6 toolchain (the package currently compiles in Swift 5 language mode)

## Develop

```sh
make build
make test
make run
```

Run `make help` to list all development commands. The Makefile is a thin,
discoverable entry point; SwiftPM still owns compilation and dependency
management, while shell scripts own multi-step packaging operations.

`make run` builds the app bundle and launches its executable in the foreground,
so the process uses the same bundle identity and `LSUIElement` metadata as the
Accessibility permission entry. Stop it with `Ctrl+C`.

## Build an app bundle

```sh
make app
open .build/app/Winnow.app
```

Use `make verify` to build the bundle and validate its Info.plist and signature.
The underlying script creates `.build/app/Winnow.app` with `LSUIElement=true`.
It performs an ad-hoc signature for local development only; Developer ID
signing and notarization belong to the release version.

Because the local signature is ad hoc, changing the executable can invalidate
the existing Accessibility grant. If that happens, remove the old Winnow entry
from System Settings, run `make app`, add `.build/app/Winnow.app` again, and
restart Winnow without rebuilding it.

## Validate Accessibility window switching

1. Build and open `.build/app/Winnow.app`.
2. Grant Winnow access in System Settings → Privacy & Security → Accessibility.
3. Open the Winnow menu-bar item and expand `Debug Windows`.
4. Select a window and verify that hidden applications are revealed, minimized
   windows are restored, and the selected window receives keyboard focus.

The minimum manual matrix is Finder, Safari, Xcode, Chrome, and one Electron
application in normal, hidden, and minimized states. Also verify startup without
permission, permission revocation while Winnow is running, and rapid repeated
switching while the main thread remains responsive.
