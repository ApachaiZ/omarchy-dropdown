# Validation

Environment where the graphical checks were run:

- Omarchy **4.0.6-1**
- Hyprland **0.56.2** (Lua configuration)
- Quickshell **0.3.2** (Omarchy build)
- Monitors: AOC Q27G4N at 2560×1440, `transform = 1`, scale 1.25
  (layout box 1152×2048 after scale/transform) and Samsung LC34G55T at 3440×1440, scale 1.25.

## Automated

| Check | Result |
| --- | --- |
| `node --test tests/*.test.mjs` | 61/61 pass |
| `bash -n install.sh uninstall.sh tests/run.sh scripts/screenshots.sh` | pass |
| `omarchy plugin validate .` | pass (exit 0) |
| Manifest entry points exist | pass |
| Example config validates | pass |
| No shell interpolation (`sh -c`, `eval`, `pkill`) in the plugin | pass |
| Geometry for top/bottom/left/right, transforms, clamps | pass |
| Webapp class derivation from real Chromium classes | pass |
| Key collision / reserved commands | pass |

## Graphical, on the real session

| Scenario | Result |
| --- | --- |
| Palette summoned by IPC and by the configured dispatcher | works |
| Palette has no idle timeout: still open after 10 s with the pointer outside | works; closes on Esc or outside click |
| Click outside the palette closes it without moving the pointer | works (synthetic click; cursor stayed at 1000,1000) |
| Click outside on another output also closes the palette | works; catcher surfaces on every screen |
| Pointer crosses to another output with the palette open | palette and visible app stay; no click, no dismissal |
| Pointer crosses to another output with an app visible | app stays visible; focus may move, then it hides after `autoHideDelayMs` |
| Click outside with an app visible | app parked immediately, as with Escape (no `autoHideDelayMs` wait) |
| Click on another window with an app visible (real pointer click) | app parked immediately, in the same second |
| Click inside the visible app | app stays; the click reaches the app (non-consuming bind) |
| Click on the bar while an app is visible | app stays (bar is a reserved edge, not an outside click) |
| Pointer leaves the visible app without clicking | app parked after `autoHideDelayMs` |
| Alt-Tab away from the visible app | app parked after `autoHideDelayMs` |
| Close the palette with the hotkey or the bar widget | fade-out completes; no blink or mid-animation unmap |
| Fixed screen + workspace 3: summon lands on workspace 3, not workspace 2/1 | works |
| App visible on another workspace: summon moves it to the current workspace instead of hiding it | works |
| Palette on the focused monitor and explicitly on the other monitor (`openOn`) | works |
| Screen setting: fixed output overrides focus; `auto` follows focus; `openOn` bypasses for scripts | works |
| Auto-hide delay: visible at 2 s, hidden at 6 s, cancelled by refocus | works |
| Shortcut editor: rebind and reset | works |
| Escape submap: hides focused/hidden-focus dropdown and resets | works |
| Palette layout: five most-used cards, tab strip, bottom shortcut band | works; compact height, equal widths, no overflow |
| All-apps drawer: Space/chevron expands every enabled app with key and direct shortcut | works; three-column grid, scrolls after three rows |
| Drawer keyboard: Down enters, arrows move, Enter opens the selected app, Esc collapses first | works (kitty → ChatGPT → Discord, Enter opened Discord) |
| Drawer selection stays in sync with the rendered columns | works; same `Keymap.columnsForWidth` used by renderer and keyboard |
| Settings: `Top cards` row changes 3–7 | works; value persisted and used by the palette |
| Direct shortcut suggestion: Enter applies it; an external conflict proposes the next one | works (`SUPER + SHIFT + K` rejected, Enter then applied `SUPER + SHIFT + I`) |
| Named shortcut keys: arrows, Tab, Space, Return, punctuation, F1–F24, Page Up/Down | works; generated Lua and `hyprctl binds -j` agree, Page Up/Down use `Prior`/`Next` |
| Named-key conflict detection (external bind) | works (`SUPER + ALT + LEFT` rejected with the owner's description) |
| `cleanup` clears generated binds and `refresh` regenerates them | works (4 binds → 0 → 4) |
| External config edit is adopted and backed up | works; `topApps` 6 adopted, timestamped backup created |
| Invalid JSON is not adopted or overwritten | works; settings stayed at 6, file left untouched |
| `doctor` reports paths, counts, state and last Hyprland error | works |
| Palette stays "open" after a hot service reload | fixed; state reset on service start and verified by `openOn` |
| Palette placed/slid from top, bottom and left | works |
| Full-screen palette; click outside closes it and releases focus | `outsideClick()` exercised directly; QML mouse catcher is standard |
| Managed window floating, brought to the top of the floating stack | works |
| Managed window reveal | shell card slides from the edge, app fades in beneath, card fades out; the app window is not moved |
| Newly launched window default-size flash | reduced to ~50 ms by the 35 ms openwindow adoption; one map frame remains |
| Reduced motion: reveal places the window directly at its final geometry | works (no intermediate position samples) |
| Fresh launch with a slow-painting web app | placed at the final geometry; no blank block slides in |
| Reveal has no intermediate frame and no app-window motion | works (parked → final; shell slide + fade observed at 60 fps) |
| New launch maps on the parked workspace, floating and transparent | works; no frame at the default tiled position |
| Palette selection → window reveal | palette hides in the same frame; no empty gap, no overlap |
| Focus loss without a click (pointer move, Alt-Tab, empty workspace) | hides after `autoHideDelayMs`; a real left click hides immediately |
| Escape after palette selection and after a direct show | hides the window in both cases |
| Direct binds verified against `hyprctl binds -j` after startup and `configreloaded` | works; missing binds trigger a re-apply |
| Fuzzy search: subsequence matches ranked by score | works ("dsc" finds Discord) |
| Reveal card shows the app icon and name | works |
| `doctorRedacted` masks app ids/names/notes | works |
| Uninstall saves bar placement, install restores it | scripts check out; placement saved to `dropdown.bar-placement.json` |
| Orphan terminal/agent window adopted on toggle and after startup | works (duplicate kitty became managed, Escape hides it) |
| A window visible at shutdown is parked at startup, not shown | works (Discord visible → restart → parked) |
| Obsidian (Flatpak) show/hide/restart cycle | works; parked on the shared special, Escape hides it |
| Relaunch after closing a single-instance app | adopts the parked window in ~1 s instead of timing out |
| Named special cannot be created at runtime | falls back to the shared special; no `Invalid workspace` |
| Alt-Tab/dock access to a parked window | adopted as current without moving it; stays open, Escape hides it and dismisses the special |
| Alt-Tab to another window while a shown-special dropdown is current | auto-hide parks it and closes the special |
| Parked windows carry `dropdown-hidden`; removed on reveal | works (hyprctl clients tags) |
| Quay ignores tagged windows | works (Quay 1.0.1 filter) |
| Palette command `t` launches kitty and adopts the new window | works |
| Recall while visible hides it; recall while hidden reveals the **same** address/window | works |
| Recall after moving focus to another monitor | works; same window moved to the requested workspace |
| Geometry on portrait 90° output | centred in the logical 1152×2048 box; no negative offsets |
| Geometry on landscape output | compact 1238×716 at (2197, 38) on HDMI-A-1 |
| Click outside a visible managed window (active window change) hides it and keeps the new window focused | works |
| Active window changes are caught through `Hyprland.activeToplevelChanged`, including dispatcher focus | works |
| `2` hides and returns focus to the window active before the palette | works |
| `q` then `t` closes only the terminal; cancels with `Esc`; reveals a hidden window first | works |
| Quit mode rejects a key with no running app and leaves the prompt open | works |
| Ordinary browser window untouched | works |
| Ordinary Nautilus window not captured; explicit `o` adopt; `u` release | works |
| Default terminal in a dedicated app-id window | works |
| Default agent (`opencode`) in a dedicated terminal | works |
| Default file manager | works |
| Rapid duplicate invocation | one window |
| Plugin disable removes managed windows from the special workspace | works (terminal process survives; window returns to a real workspace) |
| State recovery after a full shell restart | visible/parked windows re-adopted from the state file |
| Sizes: presets, edge, width/height/offsets, per-app override/reset | works |
| Animations: palette in/out mode (12 choices), duration/easing, reduced motion | works |
| Hide delay in `s` → Behaviour: 5 s → 6 s → 5 s, palette stays open | works |
| Manage → D captures a direct chord and writes the generated bind | works (`CTRL + ALT + J` for kitty, then cleared) |
| Duplicate direct chords are rejected | works (a second app refuses a chord owned by another app) |
| Clearing a direct shortcut removes its generated bind and reloads Hyprland | works |
| Generated binds survive a Hyprland reload and a shell restart | works |
| Direct shortcut check includes Omarchy/default/user binds | works (`SUPER + N` → Centre de notifications; `SUPER + SHIFT + G` → Signal) |
| UI conflict message stays in capture mode and does not change the config | works (`CTRL + ALT + J` already used by Agent) |
| A free chord is applied after the async check | works (temporary example chord, then cleared) |
| Animation mode cycling: Fade → Slide + Fade → Fade | works; config saved live |
| Bar widget instantiated on both screens | works (window glyph in the left section of both outputs) |
| Bar widget open path targets its own screen | works via `openPalette(view, hostScreenName)` |
| Preview: an app key opens the matching window and closes the preview | works (hidden kitty revealed with `t`) |
| Preview: reserved command key never opens the app | works (`b` conflict: red `reserved · Bar`, red hint, red flash) |
| Preview: `Enter` and click still open a conflicted app by id | works |
| Tab strip at the top of the palette; active tab tracks the visible window | works |
| Tab bar position setting `top` ↔ `bottom` in `s` | works; persisted to `settings.tabs.position` |
| Tabs wrap onto a second row when the palette width is exceeded | works (two-row test) |
| Tabs cap at three rows and scroll to the active tab beyond that | layout capped at `maxRows: 3`; overflow path not exercised |
| `Enter` after `Ctrl+Tab` keeps the window and closes the palette | works (Agent stayed visible) |
| Next-window key `w` switches once and closes the palette | works |
| `Ctrl+Tab` / `Ctrl+Shift+Tab` cycles visible/hidden managed windows | works; palette stays open, one visible at a time |
| Configurable next-window key (`w`) cycles the same list | works |
| Pop out with `'` then an app key | works; the window became normal and tiled, palette closed |
| Popped-out window is not re-adopted after state reloads | works after the state-file watcher was restricted to startup |
| Pop-out prompt and `Esc` cancel | works |
| Bar placement view: section cycle, index step, `r` reload, `Esc` close | works; live apply keeps the palette open |
| Bar placement applied to left, centre and right in sequence | works (`omarchy bar move` with 0-based index) |
| Changing Screen in `s` keeps the palette open | works; preference saved for the next open |
| Geometry/tab-position settings keep the palette open | works |
| Bar widget remains visible after moving it on a portrait output | works in the left section; the centre/right sections of that bar can render off-window |

## Not exercised, and why

- **The physical `Super + Alt + ;` chord.** `wtype` cannot inject a usable
  Super modifier in this session (Alt works, Super does not reach Hyprland's
  bind handler). `hyprctl binds` confirms the bind and the dispatcher, and the
  same dispatcher was exercised through `omarchy-shell`. `xkbcli how-to-type`
  confirms `;` is keycode 47 with no modifier on the active `fr(us)` layout.
- **Pointer-driven 3D tilt on cards, icons and tabs.** The cursor injector
  (`hyprctl dispatch movecursor`) did not move the pointer in this session, so
  the tilt was verified from the bindings and a clean static render, not from
  a real hover.
- **A real pointer click outside the palette or on a tab.** No
  `ydotool`/`wlrctl` is installed. The QML catchers call `outsideClick()` and
  `switchToTab()` directly; those functions were exercised through the
  keyboard path, which is the same code.
- **Live monitor hotplug/removal and scale change.** The code listens to
  Hyprland monitor events and revalidates the visible window; no output was
  physically disconnected during the checks. `openOn` covers the per-screen
  placement path.
- **Blocking application quit confirmations.** Chromium and Nautilus closed
  directly. The implementation reveals a hidden window before sending the
  close request, so a confirmation is on screen, but a real blocking dialog was
  not scripted.
- **A shell process crash** (SIGKILL). The state file and special-workspace
  orphan recovery are implemented; only a clean shell restart was tested.
- **Right-edge visual placement.** Covered by the geometry unit test; top,
  bottom and left were rendered.

## Known limitations

- The file manager's window class is shared with ordinary windows. A dedicated
  file-manager instance is identified by the pre-launch window snapshot;
  dialogs are not parked/restored with it.
- The palette is modal while open: the click that dismisses it is consumed and
  focus returns to the window that was active before the palette.
- The managed window is placed directly and faded in (four opacity steps); it
  does not slide. Reduced motion turns the fade off.
- The preview is a stylised application card (icon, title, state, key), not a
  screen capture. This avoids exposing another window or stale pixels; live
  toplevel capture was not reliable on this compositor build.
- The global Escape submap intercepts Escape while a dropdown is visible; an
  application that relies on Escape for its own modal can lose that key until
  the dropdown is hidden.
- Hidden applications keep their process, GPU surfaces and network activity.
  Dropdown never suspends them.
- A plugin code hot-reload restores parked windows and re-adopts visible ones.
  The palette flag is reset in 0.6.0, but QML component caches can still serve
  an older file; restart `omarchy-shell` after changing QML while developing.
- The real plugin-disable path was exercised through the shared `cleanup` IPC
  and `pluginStillEnabled()` logic; a full disable was not run on the capture
  session because it would unpark the author's windows.
