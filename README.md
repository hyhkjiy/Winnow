# Winnow

Winnow is a Swift + AppKit macOS window searcher under active development.

The current implementation deliberately focuses on architectural boundaries:

- an `LSUIElement` menu-bar application shell;
- a native Carbon global hot key;
- Accessibility and Screen Recording permission checking and prompting;
- one synchronized `NSPanel` per screen with a single input owner;
- privacy-safe logging and in-memory-only window models;
- Accessibility window discovery with Core Graphics metadata and an isolated,
  optional private bridge for real WindowServer identity;
- an in-memory window index refreshed by Accessibility, application lifecycle,
  and active Space events.

The global search overlay now performs asynchronous window discovery, mirrors
loading and error state across every display, and renders an adaptive result
list: applications with one switchable window appear as direct rows, while
multi-window applications remain grouped. The shared search session keeps the
query, filtered results, and keyboard selection synchronized across panels.
Arrow keys move the selection, and Enter or a mouse click activates the target
window. Application names, window titles, and Chinese pinyin initials are
searchable.

The menu-bar `Debug Windows` submenu remains available as a secondary validation
path. Plain rows have a confirmed WindowServer identity; `≈` rows have an AX
reference without a confirmed WindowServer ID. A timed-out application's cached
windows are explicitly labeled `Last known` in search. Full MRU ordering remains
a later implementation slice.

## Window service boundaries

Search reads AX windows and an immediate Core Graphics snapshot. It does not
wait for ScreenCaptureKit or request Screen Recording permission. The optional
ScreenCaptureKit inventory is retained for broader discovery/recovery calls,
but capture eligibility is not treated as proof that a window can be controlled.
Windows without an AX reference are not presented as switchable search results.

`WindowIdentityBridge` dynamically resolves `_AXUIElementGetWindow`. If it is
unavailable, identity falls back to AX element equality; title and geometry
matches never establish an exact WindowServer identity. Set
`WINNOW_DISABLE_PRIVATE_WINDOW_ID=1` in the app process environment to exercise
the fallback. This bridge does not enumerate or control macOS Spaces.

AX discovery runs on a bounded worker pool with per-process and batch deadlines.
A slow process cannot indefinitely delay publishing healthy results; timed-out
calls remain single-flight because a synchronous AX call cannot be forcibly
cancelled. Short-lived stale snapshots preserve continuity without claiming a
fresh successful scan. The UI caches snapshots, merges refresh requests, and
uses both events and periodic reconciliation because AX events can be missed.
Activation uses a separate queue from discovery.

These boundaries follow Apple's [AX timeout semantics](https://developer.apple.com/documentation/applicationservices/1459345-axuielementsetmessagingtimeout)
and [capture inventory definition](https://developer.apple.com/documentation/screencapturekit/scshareablecontent).
The isolated ID bridge has precedent in [AeroSpace](https://github.com/nikitabobko/AeroSpace).
No guarantee is made that every application exposes every native Space or tab
through AX; supported combinations still require the manual matrix below.

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

`make run` builds the app bundle and asks LaunchServices to open it, so macOS
attributes Accessibility requests to Winnow instead of the terminal that
started the command. Use the Winnow menu's Quit command to stop it; `make run`
returns after the app exits.

## Build an app bundle

```sh
make app
open .build/app/Winnow.app
```

Use `make verify` to build the bundle and validate its Info.plist and signature.
The underlying script creates `.build/app/Winnow.app` with `LSUIElement=true`.
The default build requires a valid `Winnow Local Development` code-signing
identity so the app keeps the same designated requirement across rebuilds. Set
`WINNOW_CODE_SIGN_IDENTITY` to select another valid identity. The build fails
before compilation when that identity is unavailable; it never silently falls
back to ad hoc signing.

The bundle is assembled and signed in a temporary directory. Its identifier,
signature, and designated requirement are verified before it replaces the
existing app. When an existing `.build/app/Winnow.app` is present, the new
designated requirement must match it exactly. A signing or verification failure
therefore leaves the previous bundle in place. Run `make verify-signing` to print
the current identifier and designated requirement without rebuilding.

`make app-adhoc` remains available for packaging tests and writes to the separate
`.build/app-adhoc/Winnow.app` path. `make run` always rebuilds the stable-signed
`.build/app/Winnow.app` and never launches the ad hoc package. Developer ID
signing and notarization still belong to the release version.

After switching from an ad-hoc signature to a stable development identity,
remove the stale Winnow entries from System Settings once, rebuild the app, and
grant Accessibility and Screen Recording to the newly signed app. Subsequent
rebuilds with the same identity should retain those grants.

## Validate window discovery and switching

1. Build and open `.build/app/Winnow.app`.
2. Grant Winnow access in System Settings → Privacy & Security → Accessibility.
3. Screen Recording is optional for the search path. If validating the broader
   inventory, grant it from Winnow's menu or Settings window.
4. Put windows from the same application on multiple Spaces, including a
   full-screen Space, then expand `Debug Windows`.
5. Select each row and verify that hidden applications are revealed, minimized
   windows are restored, and the selected window receives keyboard focus.

To capture a repeatable discovery report using the signed app's real TCC
identity, run:

```sh
open -n -W .build/app/Winnow.app --args --diagnose-windows /tmp/report.json
```

The diagnostic performs three read-only window scans, writes the report, and
exits without initializing `AppDelegate` or registering the global hot key.
Check the report's `status`, not merely whether `open` exited successfully.
Each scan has a three-second diagnostic deadline. Reports contain counts,
identity continuity, freshness, and timing, without window titles.

The minimum manual matrix is Finder, Safari, Xcode, Chrome, and one Electron
application in normal, hidden, and minimized states. Also verify startup without
either permission, permission revocation while Winnow is running, duplicate
window titles, Space changes, full-screen transitions, Stage Manager, and rapid
repeated switching while the main thread remains responsive.
