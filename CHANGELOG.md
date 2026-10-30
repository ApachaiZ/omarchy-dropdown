# Changelog

All notable changes to Dropdown are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/) and the project uses semantic
versioning for plugin releases.

## 0.7.10 — 2026-10-31

### Fixed

- Moving the pointer to another output no longer hides the visible dropdown
  when its window still owns keyboard focus. Hyprland updates the focused
  monitor/workspace on pointer crossing even with `follow_mouse` disabled, and
  the workspace check ran before the active-window check.
- The palette no longer closes as soon as the pointer crosses to another
  output. The `focusedmon` raw event fired on pointer moves, not only clicks;
  the full-screen catcher on every output already handles real outside clicks.
- An outside click hides a visible dropdown immediately, like Escape, while a
  click inside it (or on its dialogs or the bar) is ignored. The click is
  reported by a non-consuming `mouse:272` bind in the `apach-dropdown` submap.
  Pointer moves and focus changes keep `autoHideDelayMs`, so moving the pointer
  out of the window no longer closes it at once.
- The palette tells the shell when it closes itself, so a stale open state
  cannot replay it on the next summon.
- The palette close animation is no longer cut short. The plugin is
  `keepLoaded`, so closing it through the shell (hotkey or bar widget) lets the
  fade finish instead of unmapping the surface mid-animation.

## 0.7.9 — 2026-10-30

### Added

- Parked windows now carry the Hyprland tag `dropdown-hidden` (removed on
  reveal, release or restore). Launchers and docks can filter it out:
  Quay 1.0.1 ignores it, so hidden Dropdown apps no longer appear as running
  there.

## 0.7.8 — 2026-10-30

### Fixed

- Selecting a parked window from Alt-Tab or a dock no longer closes it: the
  focused parked window is adopted as the visible dropdown without being
  moved, so Escape and focus-loss auto-hide work immediately. Moving it first
  caused a reveal/toggle loop on the shared special workspace.

## 0.7.7 — 2026-10-30

### Fixed

- A parked window revealed from Alt-Tab or a dock (which activates its special
  workspace) is now adopted as the visible dropdown again: Escape hides it,
  focus-loss auto-hide works, and the special workspace is dismissed when it
  is parked back.
- `monitors[].specialWorkspace` is refreshed on `activespecial`/`workspace`
  events, so direct access is detected immediately.

## 0.7.6 — 2026-10-30

### Fixed

- This Hyprland build refuses to create a new named special workspace at
  runtime. Dropdown now falls back to the shared unnamed special workspace
  for apps whose per-app workspace does not exist yet, so parking never fails
  with `Invalid workspace`.
- A managed special workspace now always counts as parked, whatever its exact
  name; a window visible at shutdown is parked at startup and not shown again.
- Launching a single-instance app (Obsidian/Flatpak) adopts the existing
  parked window instead of waiting 20 s for a window that never maps.
  Orphan recovery no longer steals a window that belongs to an in-flight
  launch, and a stale registry entry for the same app is recoverable.

## 0.7.5 — 2026-10-30

### Fixed

- The reveal card is now rendered by the service itself instead of the
  overlay. Cross-object bindings and Connections on the injected service
  object were not reactive in this shell instance, so the card never became
  visible. Local bindings make the slide reliable everywhere.

## 0.7.4 — 2026-10-30

### Fixed

- The reveal card did not slide when an app was opened from a direct
  shortcut: the panel had no frame to paint its start position before the
  move. The card now waits one compositor frame at the start before sliding.

## 0.7.3 — 2026-10-30

### Cleanup

- Bind verification is throttled to once per 3 s across `configreloaded` bursts.
- Full dead-code/component scan: no unused functions, imports or components
  left; the only remaining duplication was removed in 0.6.9/0.7.0.

## 0.7.2 — 2026-10-30

### Fixed

- The reveal shell was driven by a service signal that never reached the
  overlay, so the slide silently fell back to a plain fade. The shell state is
  now a set of service properties read by bindings, which always propagate.
  The slide card (icon + name) is back.

## 0.7.1 — 2026-10-30

### Fixed

- The reveal payload referenced the app without passing it into
  `requestShellSlide`, throwing a ReferenceError that left windows invisible
  (and could stall their launch). The fallback timeout is armed before the
  payload is built, so a failure can never leave a window hidden again.

## 0.7.0 — 2026-10-30

### Added

- Manage search is now fuzzy: subsequence matches with word-start bonuses,
  results ranked by score.
- The reveal card shows the app icon and name while it slides in.
- `doctorRedacted` IPC: the support bundle with app ids/names/notes masked.
- Uninstall saves the bar widget placement and a reinstall restores it.
- `Model.fuzzyScore`, `Model.missingBinds` and `State.autoHideReason` hold the
  pure logic behind search, bind verification and focus loss, with tests.

## 0.6.9 — 2026-10-30

### Cleanup

- Extracted the shared Up/Down/Left/Right/Enter/R navigation used by the
  Settings, Animations and per-app size views into `handleAdjustKeys()`.
- Palette commands use one view map instead of six identical branches.
- `DEFAULT_COMMANDS` is defined once and reused by the default config.

## 0.6.8 — 2026-10-30

### Changed

- A window that was visible when the session ended is no longer restored
  visible at startup: it is parked on its special workspace instead. Apps
  only appear again when explicitly recalled. This stops Discord (or any
  dropdown) from popping open at every login or shell restart.
- Recovered orphan terminal/agent windows are parked too, not shown.

## 0.6.7 — 2026-10-30

### Cleanup

- Removed dead helpers (`Model.ease`, `State.canAdopt`, `State.isTerminal`)
  and their tests; nothing at runtime used them.
- Deduplicated `luaString` (Service now uses `Shortcuts.luaString`) and the
  drawer card state label (uses `Model.stateLabel`).
- Extracted the shared auto-hide condition into `autoHideReason()` and the
  client-callback drain into `drainClientCallbacks()`, removing two
  duplicated copies each.

## 0.6.6 — 2026-10-30

### Fixed

- Direct shortcuts could disappear from Hyprland's live bind table after a
  config reload that raced the generated bind file. The service now verifies
  `hyprctl binds -j` on startup and after every `configreloaded` event and
  re-applies the binds when one is missing.
- The Escape submap is re-armed after a Hyprland config reload (reload resets
  submaps).
- A terminal or agent window left visible after a plugin reload (duplicate
  kitty) is now adopted when the app is toggled and on startup, so Escape and
  focus-loss hiding work on it again.

## 0.6.5 — 2026-10-30

### Changed

- The reveal is now a compositor-animated shell: an empty card with the
  window's geometry slides in from the configured edge, the real window is
  placed at its final position and fades in beneath it, then the card fades
  out. The app window itself is never moved, and no Python process is
  involved.
- Removed `settings.animations.windowSlide` and
  `settings.animations.windowDurationMs` and their Animations rows. Reduced
  motion shows the window instantly.

## 0.6.4 — 2026-10-29

### Changed

- The managed-window slide is now a 120 Hz tween driven by a single Python
  process over the Hyprland request socket. It no longer spawns `hyprctl` for
  every frame, which caused the visible stutter and missing frames.
- `settings.animations.windowDurationMs` controls the window slide separately
  from the palette (default 260 ms, 0–800); `Window duration` is back in
  Animations. `Window slide` still disables the motion entirely.

## 0.6.3 — 2026-10-29

### Fixed

- A launched app no longer appears at its default tiled position before being
  placed. It is started through Hyprland with window rules that map it directly
  on its parked special workspace, floating and transparent, then Dropdown
  adopts it.
- Selecting an app closes the palette in the same frame instead of leaving a
  fade/empty gap before the window reveal.
- Hyprland's own window animation is disabled with `no_anim` while the
  position tween runs, so it cannot fight the slide.
- Focus loss is detected by comparing the focused workspace with the window's
  workspace, not only the active toplevel. Moving to an empty workspace or the
  desktop now hides the dropdown after the configured delay.
- Escape is re-checked after the palette closes and after the fresh-launch
  path; the submap is armed as soon as a window is current.

## 0.6.2 — 2026-10-29

### Fixed

- Newly launched apps no longer slide in as a grey/white unpainted block.
  A fresh window is placed directly at its final geometry, kept invisible for
  a short paint delay, then revealed. The slide is reserved for windows whose
  content is already loaded.
- An interrupted or failed reveal restores the window opacity, and recovered
  windows are made visible again after a crash.

### Added

- `settings.animations.windowDurationMs` (default 320 ms, 0–800) controls the
  managed-window slide independently from the palette duration. 180 ms across
  a full screen felt like a jump; the new default is a visible slide.
- The Animations view exposes `Window duration`.

## 0.6.1 — 2026-10-29

### Fixed

- The managed window no longer appears at its previous (often centred)
  position and then jumps upward before sliding down. Fullscreen, float,
  resize, workspace move and the off-screen start position are now applied in
  one `hyprctl --batch`, so no intermediate geometry is rendered.
- The slide tween no longer runs while the window is still parked, so the
  movement is visible from the first frame instead of being partly consumed
  off screen.
- Newly launched windows are adopted 35 ms after `openwindow` instead of
  120 ms, reducing the default-size flash before the dropdown takes over.

## 0.6.0 — 2026-10-29

### Added

- All-apps drawer under the five cards: `Space`, the `All apps` row or the
  chevron expands a card for every configured application.
- Full keyboard navigation in the drawer: arrows move through the grid, `Enter`
  opens the selected app, `Escape` collapses the drawer before the palette.
- Responsive drawer: one to three columns depending on the card width, and a
  height capped from the monitor height.
- `settings.topApps` (3–7) controls how many cards sit above the drawer.
- Direct-shortcut capture accepts arrows, Tab, Space, Return, navigation keys,
  F1–F24 and common punctuation in addition to letters and digits.
- `Enter` during capture applies a suggested free chord. A chord already owned
  by an Omarchy/Hyprland bind is rejected and the next free suggestion is shown.
- `omarchy-shell apach.dropdown doctor` prints paths, live counts, app state,
  last Hyprland dispatch error and the generated shortcut state.
- `omarchy-shell apach.dropdown cleanup` clears the generated direct binds.
- `js/Keymap.js`, `js/Shortcuts.js`, `js/ConfigFile.js` and `js/State.js` hold
  the pure decision logic, with unit tests for each.
- GitHub Actions CI: unit tests, shell syntax, manifest and plugin validation.

### Changed

- `Service.qml` and `Overlay.qml` delegate key routing, shortcut validation,
  bind generation, config-file policy and window-state labels to tested modules;
  the all-apps drawer is its own `components/AllAppsDrawer.qml`.
- Config saves are atomic and tagged as our own write, so an external edit is
  adopted instead of being silently overwritten. External edits create a
  timestamped backup (five kept), and invalid JSON never replaces settings.
- The shortcut `D` and startup `A` actions no longer require Shift in Manage.
- Disabling the plugin now clears the generated direct binds; a normal shell
  reload still preserves parked windows and binds.
- A launch that maps its window exactly at the timeout gets a 900 ms grace
  period instead of a false failure.

### Fixed

- Palette state could stay "open" after a hot plugin reload, causing the next
  `openOn` to be ignored.
- Card frames and icons stay intact during tilt and wobble.
- Long app names no longer overflow drawer cards.

## 0.5.2 — 2026-10-29

- Give the drawer grid padding inside its Flickable and inset card frames
  further, so borders are not clipped while cards wobble.

## 0.5.1 — 2026-10-29

- Keep card borders and icons intact during hover tilt and drawer wobble.

## 0.5.0 — 2026-10-29

- Add the all-apps drawer with staggered reveal and hover wobble.

## 0.4.0 — 2026-10-29

- First public release: native dropdown windows, parked sessions, tabs,
  preview, pop-out, quit mode, direct shortcuts, configurable animations.

[Keep a Changelog]: https://keepachangelog.com/
