# Architecture

Dropdown is an Omarchy shell plugin with three entry points and a small set of
pure modules. This page is for people changing the code; end-user behaviour is
documented in the main [README](../README.md).

## Entry points

| File | Role |
| --- | --- |
| `Service.qml` | Long-lived singleton. Owns config/state persistence, the app catalog, the managed-window registry and every Hyprland dispatch. |
| `Overlay.qml` | Layer-shell palette and menus. Thin view over the service; no window management of its own. |
| `BarWidget.qml` | Bar button and tooltip. Left click toggles the palette, right click opens Manage. |

`manifest.json` declares all three kinds. The service is enabled through
`plugins[]` in `shell.json`; the bar widget can be placed independently.

## Pure modules

The decision logic is split out so it can be tested with `node --test` without
a compositor:

| Module | Responsibility |
| --- | --- |
| `Model.js` | Config validation, URL/web-app identity, geometry, monitor parsing, shortcut normalization, key allocation. |
| `js/Keymap.js` | Palette intent from a key press and grid movement in the drawer. |
| `js/Shortcuts.js` | Shortcut ownership rules, Hyprland bind conflicts, Lua bind rendering. |
| `js/ConfigFile.js` | Config serialization, self-write detection, backup names, invalid-JSON policy. |
| `js/State.js` | Managed-window state labels and the secondary state note. |

`tests/*.test.mjs` covers all five. Anything that needs Qt, Hyprland or a live
window belongs in QML, not in these files.

## Service lifecycle

```
desktop entry scan ──► catalog ──► palette cards / Manage rows / drawer
Hyprland clients ────► registry ─► one visible dropdown, globally
config file ─────────► config ───► generated binds + geometry + commands
state file ──────────► recovery ─► re-adopt parked windows after a shell restart
```

- **Parked windows.** A hidden dropdown is moved to its own Hyprland special
  workspace (`special:dropdown-<app>-<hash>`), not closed. Every app has a
  separate workspace, so Alt-Tab never shows a pile of hidden windows. The
  state file records its address so a shell restart can recover it; a
  migration moves windows parked by older builds off the shared unnamed
  special.
- **Launch preemption.** Before starting an app the service arms
  `_dropdownPending` with `hyprctl eval`. `hypr/dropdown.lua` registers a
  compositor `window.open` handler that floats the new window, moves it to
  its parking workspace, sets opacity 0 and tags it `dropdown-hidden` in the
  same compositor pass that maps it. Chromium and Electron create their
  toplevel before the window-rule engine can see the class, and `exec` rules
  only follow the spawned PID (they miss windows created by an already
  running browser), so this handler is the only mechanism that catches every
  window before it is painted. The entry expires after 30 s and is cleared
  as soon as the window is adopted; an `openwindow` hyprctl fallback handles
  a missing hook.
- **One visible dropdown.** `revealApp` reuses the current window when another
  app is requested, moving it to the requested monitor/workspace instead of
  creating a second dropdown.
- **Reveal order.** Fullscreen is cleared first, then the window is floated,
  resized and moved to the target workspace at its final geometry, invisible.
  The service renders an empty card with the same geometry that slides in
  from the configured edge (compositor-animated). Once it arrives, the window
  fades in beneath it and the card fades out. The app window is moved and
  resized in one batch while transparent; no external process animates it.
- **Context capture.** `capturePaletteContext` reads the live Hyprland monitor
  and workspace at open time; it does not use a cached monitor list, so a fixed
  screen follows that screen's current workspace.
- **Dispatcher queue.** All `hyprctl dispatch` calls go through one bounded
  helper and a capped FIFO queue (64 entries, oldest dropped with a warning);
  a failed, timed-out or oversized dispatch is recorded in `hyprError` and
  exposed in `status`/`doctor`.
- **External helpers.** Every `Process` is a `BoundedProcess`: per-stream byte
  caps, an absolute deadline, SIGTERM then SIGKILL, failed-start detection and
  one terminal result. Output is captured as raw bytes by `StdioCollector` and
  decoded once from the complete bounded buffer, so a multi-byte UTF-8
  character split across two reads is not corrupted. JSON helpers are
  producer-bounded (`timeout … | head -c`); a truncated payload is a failure,
  never a partial parse.

## Config writes

Only the service writes `~/.config/omarchy/dropdown.json`.

1. Every mutation clones the config, validates the result and marks it dirty.
2. `saveConfigNow` serializes with `ConfigFile.encode`, records the exact text
   as `lastConfigWrite`, then writes atomically.
3. `FileView` only notifies changes (`preload: false`) and performs atomic
   writes; it never supplies file content. The service re-reads through
   `timeout head -c` (1 MiB cap). A change whose text equals `lastConfigWrite`
   is our own write and is ignored.
4. A real external change is backed up (`dropdown.json.bak-YYYYMMDD-HHMMSS`,
   five kept), then adopted. Invalid JSON is backed up but never adopted:
   settings stay in memory and the file is left for the user to fix. A file
   above the cap is refused without touching the previous configuration.
5. If local edits are pending, they win: the file is backed up and rewritten.

## Direct shortcuts

`apps.<id>.shortcut` stores a normalized chord (`SUPER + SHIFT + D`). The
service renders `~/.config/hypr/dropdown-binds.lua` with one
`o.bind(..., { submap_universal = true })` per enabled app. `hypr/dropdown.lua`
loads that file at startup and defines the bare-`Escape` submap.

Assignment is asynchronous: `hyprctl binds -j` is parsed and any bind with the
same modmask/key rejects the chord, including Omarchy defaults and user binds.
Non-letter key names are lowercased for Hyprland (`LEFT` → `left`). The file is
only rewritten when its content actually changes, so a no-op save does not
reload Hyprland.

Disabling the plugin destroys the service. `pluginStillEnabled()` reads the
plugin registry: on a shell reload the plugin is still enabled and nothing is
touched; on a real disable/removal the generated binds are cleared and parked
windows are restored as ordinary windows.

## Overlay rendering

- One full-screen click catcher per monitor dismisses the palette without
  moving the pointer. The catcher, not the `focusedmon` raw event, handles
  outside clicks: Hyprland emits `focusedmon` on pointer moves, so reacting to
  it closed the palette as soon as the pointer crossed outputs.
- An outside click on the catcher parks a visible dropdown immediately, like
  Escape, even though the palette layer still owns keyboard focus.
- While a dropdown is visible, the `apach-dropdown` submap also binds
  `mouse:272` with `non_consuming = true`. Each left click is reported to the
  service, which compares `hyprctl cursorpos` with the window rect and parks
  the dropdown immediately when the click is outside. Clicks inside the
  window, its dialogs and the reserved bar edges are ignored. Pointer moves and
  focus changes only start `autoHideDelayMs`.
- The overlay is `keepLoaded`: the shell's `hide()` calls `close()` without
  destroying the layer surface, so the fade-out finishes instead of being cut
  mid-animation. A self-close also calls the shell's `hide()` to clear its open
  flag, so no stale state can replay the palette later.
- The palette is a `PanelWindow` anchored on the target monitor with a fixed
  card width; the managed window's geometry comes from `Model.geometryFor`
  and is re-applied when monitors change.
- Tabs, the shortcut band, Manage, Preview, Settings, Animations and Help are
  all views inside the same card; the all-apps drawer is
  `components/AllAppsDrawer.qml`.
- The drawer columns are derived from its rendered width
  (`Keymap.columnsForWidth`) so keyboard movement always matches the layout.

## Adding a view or a key

1. Add the action name and default key to `DEFAULT_COMMANDS` in `Model.js`.
2. Add the row to `settings.commands` in the example config if it should be
   discoverable.
3. Handle the intent in `Overlay.handlePaletteKey` (or a dedicated handler).
4. Add a test in `tests/keymap.test.mjs` if the routing is non-trivial.
