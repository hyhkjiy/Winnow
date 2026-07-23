# Winnow

Winnow is a minimal Swift + AppKit skeleton for a macOS window searcher.

The current skeleton deliberately focuses on architectural boundaries:

- an `LSUIElement` menu-bar application shell;
- a native Carbon global hot key;
- Accessibility permission checking and prompting;
- one synchronized `NSPanel` per screen with a single input owner;
- privacy-safe logging and in-memory-only window models;
- protocols for window discovery and activation.

Window enumeration, activation, MRU ordering, and pinyin matching are intentionally
left behind explicit interfaces for the next implementation slices.

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

Running with `make run` is useful for development, but it does not apply the
bundle metadata required by an Agent application.

## Build an app bundle

```sh
make app
open .build/app/Winnow.app
```

Use `make verify` to build the bundle and validate its Info.plist and signature.
The underlying script creates `.build/app/Winnow.app` with `LSUIElement=true`.
It performs an ad-hoc signature for local development only; Developer ID
signing and notarization belong to the release version.
