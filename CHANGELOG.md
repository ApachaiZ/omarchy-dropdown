# Changelog

All notable changes to Dropdown are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/) and the project uses semantic
versioning for plugin releases.

## 0.8.3 — 2026-11-13

### Security

- Every finite detached call now runs under a global `timeout -k 1 N` through
  a single helper (`Bounds.detachedCommand`). This covers the `hyprctl reload`
  paths, the detached dispatch used by launch and restoreAll, the disarm
  `hyprctl eval`, and the startup `mkdir -p` (5 s each), plus the
  launch-preemption park (3 s). No `Quickshell.execDetached` call site can
  bypass the deadline; a hung detached process is terminated by the wrapper.
- Config backups now cap destination bytes at the 1 MiB config read cap. The
  copy writes to a deterministic `<target>.part`, renames it atomically only
  after `cp` succeeds, and removes the temporary on failure, timeout or a
  SIGKILL of the wrapper. A source above the cap exits 75 before creating any
  file, the source stays intact, and the write barrier is kept with a dedicated
  notice (`service.configBackupTooLarge`).
- The backup prune excludes `.part` files from the five kept backups and
  removes stale parts (older than two minutes) so a crashed copy cannot be
  counted as a backup or linger.

Preuves: `node --test tests/*.test.mjs` (152/152), `./tests/run.sh`,
`bash -n`, `omarchy plugin validate .` and `qmllint` on the changed QML.

## 0.8.2 — 2026-11-13

### Fixed

- stderr is capped at the producer, not only by the QML receiver. The shared
  wrapper runs the helper under `timeout` and pipes stderr through a
  synchronous bounded reader (`head -c cap+1`, then a drain to /dev/null), so
  a chatty helper can neither grow the buffer nor lose its diagnostic before
  `exited`; the excess is drained instead of SIGPIPE-killing the helper.
  Every `BoundedProcess` uses this wrapper (the per-instance opt-out was
  removed); the per-chunk watcher and the exact UTF-8 final check remain as
  defence in depth.
- External config edits are adopted only after a bounded, awaited backup.
  `backupConfig` runs `cp` in a `BoundedProcess` and the write or adoption is
  deferred to its success; a failure notifies and keeps the existing
  configuration. A request made while a copy is running is kept as one
  pending intent, never a concurrent copy; a deferred save is not replayed
  after a refused-write completion, which already wrote the current
  configuration. Backup names carry milliseconds and a per-process sequence,
  so two copies started in the same second never overwrite each other. The
  five-backup prune runs through the same bounded wrapper instead of
  `Quickshell.execDetached`.
- A reveal batch that arrives while `hyprctl --batch` is running is queued in
  a bounded FIFO and run through the bounded wrapper instead of a detached
  fallback. Every batch settles its callback exactly once (success, failure,
  timeout, cancellation, or queue saturation, where the rejected batch logs
  and still runs its callback so the reveal is never blocked). Expressions of
  one lot are still applied in a single `hyprctl --batch` pass. The only
  remaining detached batch is the launch-preemption park, which must survive
  QML destruction; it is explicitly bounded with `timeout -k 1 3` and its
  output is not captured.
- After a failed adoption backup, the refusal barrier is restored: automatic
  saves (usage stats, generated keys, config normalization) are blocked so
  they cannot overwrite an external file that was not backed up. An explicit
  user save retries the bounded backup first. A save requested during another
  copy is retained and run afterwards, never dropped.

## 0.8.1 — 2026-11-13

### Security

- Manage search paste is bounded before Qt sees it. Every keyboard paste
  gesture (Ctrl+V, Shift+Insert, Ctrl+Shift+Insert) is intercepted on the
  `TextInput` and middle-click PRIMARY through a dedicated `MouseArea`; the
  field no longer runs QQuickTextInput's unbounded native paste. `wl-paste`
  runs under a 2 s `timeout` with `head -c 65537`, the consumer refuses any
  payload above 64 KiB, and a generation token cancels stale requests on a new
  paste, focus loss or close. The filter field is capped at 200 characters and
  refusals are shown as notices.

### Fixed

- Every external helper (`hyprctl`, `xdg-terminal-exec`, `xdg-mime`,
  `wl-paste`, `omarchy bar`, file reads) now runs through a shared
  `BoundedProcess`: per-stream byte caps, an absolute deadline, SIGTERM then
  SIGKILL, failed-start detection and a single terminal result. Output is
  captured as raw bytes and decoded once from the complete bounded buffer
  (`StdioCollector`), so a multi-byte UTF-8 character split across reads is
  never corrupted. `waitForEnd: false` makes the per-chunk cap effective
  before memory can grow; producer-bound helpers additionally cap stdout with
  `head -c`, while stderr stays direct so a delayed `head` cannot truncate
  it. A missing or hung binary can no longer leave callbacks, queues or the
  shortcut check blocked.
- Dispatch, client/monitor callback and launch-preemption queues have explicit
  caps; stale callbacks are dropped with a warning, and a saturated launch
  queue launches without preemption instead of losing the launch.
- `bindsCheckTimeout` terminates `hyprctl binds` and a launch watchdog expires
  launches even when `hyprctl clients` fails.
- Config, state, agent, shell.json and generated-binds files are read through
  bounded producers (1 MiB, 4 MiB, 64 KiB, 1 MiB, 1 MiB); an oversized file is
  refused rather than partially parsed, and the previous configuration is
  kept. Config apps, state entries and the desktop-entry catalog are capped.
- A failed configuration read is no longer treated as a missing file. A
  bounded `test -e`/`test -r` probe decides whether defaults may be created;
  on a timeout, overflow, permission error or unknown probe state the file is
  left intact, automatic saves are blocked, and the user is notified. An
  explicit later save runs a bounded `cp` backup and waits for it to succeed
  before writing; a failed backup aborts the save. A refused state file is
  never rewritten automatically; one bounded retry may recover it.

## 0.8.0 — 2026-11-10

### Added

- Native Omarchy translations: English and French catalogs covering every
  palette, app, settings and conflict string, following Setup > Language live.
  Languages without a catalog fall back to English.

## 0.7.15 — 2026-11-03

### Fixed

- Escape now closes the palette in one clean fade. `close()` set
  `opened = false` before `closing = true`, so the
  `visible: opened || closing` binding evaluated to false for one property
  change, unmapping the layer surface and remapping it in the middle of the
  fade (the visible flicker). The layer stays mapped until the animation
  ends.
- The palette keeps exclusive keyboard focus for the close fade, so the
  window behind does not regain focus and raise while the semi-transparent
  card is still visible. Keys pressed during that short window are ignored.

## 0.7.14 — 2026-11-03

### Fixed

- A new window is now parked inside the compositor: the service arms
  `_dropdownPending` and the `window.open` hook in `hypr/dropdown.lua` floats
  it, moves it to its parking workspace and sets opacity 0 in the same pass
  that maps it. Chromium and Electron windows created by an already-running
  browser/Electron process used to appear tiled (visually full-screen) for
  70–300 ms and reflow neighbouring windows before Dropdown adopted them.
  The entry expires after 30 s and is cleared on adoption; the `openwindow`
  dispatch remains as a fallback for an older integration file.
- Every app is parked on its own `special:dropdown-<app>-<hash>` workspace
  instead of the shared unnamed special. Windows parked by older builds are
  migrated silently on the next client refresh.
- Adopting a parked window from Alt-Tab or a dock re-applies the configured
  geometry. Hyprland translates parked floating windows when the special
  moves between outputs, which could leave them partly or fully off-screen.
- Hiding a window that is already on a parking workspace no longer stores
  that workspace as `previousWorkspace`; restoring or popping out such a
  window can no longer send it back to a hidden special.
- No monitor data is no longer treated as a valid geometry: a reveal waits
  for the monitor list once instead of placing the window at 0,0, which is
  off-screen when the layout does not start at the origin.
- A visible managed window whose current pointer was lost is re-adopted when
  it gets focus (and by `reduce`), so Escape hides it again instead of
  requiring the window to be closed.
- Monitor refresh callbacks are queued instead of overwriting each other.
- A configured URL is now an identity for apps that wrap a browser PWA
  without a `StartupWMClass` (MailFlow-style handlers): their Chromium class
  is matched and preempted at map time instead of waiting for the title to
  change, which could take much longer than the reveal.
- Dialog windows parked with an app are no longer relocated out of the
  special on the next client refresh, and an in-flight launch window is never
  moved by orphan recovery. An empty or invalid `hyprctl clients/monitors`
  payload no longer clears the registry and overwrites the state file.
- A window whose app was disabled or removed during launch is released as an
  ordinary window (unfloated, opacity restored, tag removed) instead of
  staying invisible and untracked.
- The reveal fallback timer no longer preempts long animations or skips the
  keyboard focus; a configured 0 ms duration is respected.
- Overlay transient modes (quit, pop out, key/shortcut assignment) are reset
  on open, close and view changes, so a mode cannot leak into the next palette
  session. `Ctrl+Tab` can be captured as a direct shortcut.
- The bar widget now opens on its own output even when a screen is pinned in
  Settings; a deferred palette move keeps that choice.
- Activating a system app falls back to a free key when its conventional
  `t`/`i`/`f` is already taken. App and command keys are normalized to one
  printable lowercase character.
- Close-confirmation notices expire without a client event; a stuck
  `hyprctl binds` check times out; forgetting an unrelated app no longer
  cancels a reveal or the Escape submap.
- `restoreAll` clears launch/close/error state, stops timers and saves the
  empty state; autostart is retried after a config/state load failure; URL
  migration compares case-insensitively.

### Security

- `luaString` escapes `;`, `[` and `]` so a workspace name cannot break out
  of a `hyprctl --batch` frame and inject a dispatch. Generated direct binds
  shell-quote the desktop app id.
- Config and state reject `__proto__`/`constructor`/`prototype` ids; state
  adoption requires a matching non-empty window class; existing-window
  adoption no longer trusts a page-controlled title; every URL write passes
  `isSafeUrl`.
- `doctorRedacted` masks current/last app ids, registry and launching ids,
  errors and conflicts. Opacity values are clamped and quoted; the compositor
  hook ignores malformed pending entries.

### Changed

- The installer appends the launch preemption hook to an existing
  `~/.config/hypr/dropdown.lua` when it is missing.
- Installer backups now live in `~/.config/omarchy/plugin-backups/` instead
  of inside `~/.config/omarchy/plugins/`. Quickshell scans every directory in
  the plugin root, and a backup keeps the same manifest id, so the shell
  could load the previous version instead of the freshly installed one.
  `uninstall.sh` keeps its removed copy outside the scan root too.

## 0.7.13 — 2026-11-01

### Documentation

- New project banner used as the README hero image and as the marketplace
  preview: palette overview, feature highlights and the primary shortcut in
  one image.

## 0.7.12 — 2026-11-01

### Security

- The reveal shell name is rendered as plain text, and the QML guard now also
  covers `Service.qml`.
- The security checklist now covers tooltips, buttons and labels, which render
  text through their own internal `Text` elements.

## 0.7.11 — 2026-11-01

### Security

- Every `Text` that renders dynamic content (window titles, application
  names, notices, prompts) now uses `Text.PlainText`. A browser-controlled
  window title containing HTML, for example an image tag, is displayed
  literally and can no longer make the shell fetch a remote URL when the
  Preview view opens. Reported in the marketplace review.

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
