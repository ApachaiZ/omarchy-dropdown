# Performance

## What runs at rest

- No timer is armed while the palette is closed and no launch is pending.
- No `hyprctl` subprocess is spawned at rest.
- The service keeps a small catalog, the window registry and one `FileView`
  watcher (config). The state file is read once at startup; watching our own
  writes would reload stale snapshots and re-adopt released windows. The
  generated direct-shortcut file is also read once; it has no watcher.
- `hyprctl binds -j` runs once when a direct shortcut is assigned, to reject
  conflicts with Omarchy/user/plugin binds. It is not polled.
- `hyprctl reload` runs only when the generated shortcut file actually changes
  (shortcut added/cleared, app enabled/disabled), never on a window event.
- `Hyprland.rawEvent` subscriptions are passive event handlers.
- The overlay layer surface is unmapped after its close animation.

## Catalog work

- A full catalog rebuild (desktop entries, sorting, key/conflict validation)
  only happens on a desktop-entry change, a config/key/command change, or
  enable/disable. Window events do not rebuild it.
- Client/registry events update only the changed application state and note
  rows (`refreshCatalogState`). The catalog array is replaced only when a
  row actually changed, so QML bindings stay idle otherwise.
- Monitor queries run after output/layout events only; ordinary window events
  do not spawn `hyprctl monitors -j`.
- Geometry, animation and tab-position settings update the config and, when
  needed, revalidate the visible window without rebuilding the catalog.

## What runs on an action

- Palette open: one `hyprctl clients -j` and one `hyprctl monitors -j` query,
  then the QML layer surface.
- Launch: one detached child (browser/terminal/agent), a 300 ms watcher for at
  most 20 s, and one `hyprctl clients -j` per tick.
- Reveal: 5–8 `hyprctl dispatch` calls for workspace/float/z-order/resize/move,
  plus a short position tween (24–30 ms frames for the configured duration) and
  one focus dispatch.
- Hide: one move to the app's special workspace, plus one move per parked
  dialog, then an optional focus restore after 300 ms.
- No `pkill`, no class-wide enumeration beyond `clients -j` snapshots.

## Measurement protocol

Use one shell process, idle desktop, no managed dropdown visible and the
palette closed:

```bash
pid=$(pgrep -f 'quickshell -n -p /usr/share/omarchy/shell' | head -1)
ticks() { awk '{print $14+$15}' /proc/$pid/stat; }
rss()   { awk '/VmRSS/{print $2}' /proc/$pid/status; }

t0=$(ticks); r0=$(rss); sleep 60; t1=$(ticks); r1=$(rss)
echo "cpu_ticks=$((t1-t0)) rss_kb=$r0->$r1"
```

Run it once with `apach.dropdown` enabled, then `omarchy plugin disable
apach.dropdown`, settle 5 s and run it again. The shell hosts every widget, so
the delta is the only meaningful number; absolute CPU/RSS belong to Omarchy.

## Measured on this machine

Sampling window 60 s, no input, no managed window visible:

| State | CPU ticks (10 ms each) | Result |
| --- | --- | --- |
| Dropdown enabled | 17 | 0.17 s over 60 s |
| Dropdown disabled | 18 | 0.18 s over 60 s |

The two samples are within one tick, i.e. below the 1/100 s sampling
resolution of this protocol (~0.017 % of one core). RSS moved by several MB in
both directions during the run, dominated by unrelated shell work; no
attributable resident cost is claimed.

A shorter 30 s run showed the same noise (enabled 26 ticks, disabled 8, enabled
again 8). The repeat is the reason the 60 s figures are used: idle activity
elsewhere in the shell (clock, tray, notifications) is larger than anything
Dropdown adds at rest.

## Cost of an open dropdown

That cost belongs to the application (browser/terminal/agent), not to
Dropdown. The plugin's share is the palette surface while it is open, one
registry entry and the parked-window move. A hidden window keeps its own CPU,
GPU and network cost; Dropdown does not pretend to suspend it.

## Cost of the reveal

The managed window is placed at its final geometry in one batch. A Quickshell
card with the same geometry slides in (compositor-animated layer, no
per-frame IPC), the window fades in with four opacity steps beneath it, and
the card fades out. No external process, no position tween on the app window.
Reduced motion skips the shell and the fade entirely.

Measured on this machine: five consecutive show/hide cycles kept the shell
under ~5 % of one core during activity and back to 0 % at rest (12 s idle
sampling, zero ticks). Repeated `hyprctl clients -j` payloads are skipped
without re-parsing to avoid duplicate work.
