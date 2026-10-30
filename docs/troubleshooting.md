# Troubleshooting

Start with the support bundle:

```bash
omarchy-shell apach.dropdown doctor
```

It prints the plugin version, config/binds/state paths, live counts, app states,
the last Hyprland dispatch error and the generated shortcut state. `status` is
the shorter, stable view used by scripts.

## The palette does not open

- Check the bar widget is enabled: `omarchy plugin list | grep dropdown`.
- Run `omarchy-shell apach.dropdown toggle`. A JSON result means the IPC target
  is alive; "Target not found" means the service is not loaded.
- Reload the shell once: `omarchy restart shell`. A hot reload can leave an old
  component cached; a full restart clears it.
- Inspect `doctor`: `configLoaded` and `bindsLoaded` should both be `true`.

## A managed app does not appear

- The app must be enabled in Manage. The key must be unique and not a palette
  command.
- Some Electron apps set a different window class. `doctor` shows the expected
  class and the live state note. If the window opened as an ordinary window,
  open Manage and press `o` (adopt).
- The launch timeout is 20 s with a 900 ms grace period. A timeout message now
  includes the expected class.

## A direct shortcut does nothing

- `doctor` shows the shortcut and `bindsPath`. Confirm the chord is present in
  `~/.config/hypr/dropdown-binds.lua`.
- Confirm Hyprland loaded it: `hyprctl binds -j | grep -i dropdown`.
- Re-run the assignment from Manage (`m`, Down, `d`) if the file is stale.
- A chord owned by Omarchy or another plugin is rejected with the owner's
  description; pick another chord. Dropdown never removes an external bind.

## "already bound to …"

That is intentional. The message names the existing bind and its submap. Clear
the other bind yourself, or press `Enter` to accept the next proposed free
chord. The suggestion pool learns from each rejection.

## A hot reload leaves the palette stuck

Fixed in 0.6.0: the service resets its palette flag on start. If you are on an
older build, restart the shell.

## Config edits disappear or reappear

- Dropdown writes atomically and ignores its own file-change event.
- External edits are adopted and a timestamped backup is created next to
  `dropdown.json` (five kept).
- Invalid JSON is never adopted or overwritten; the settings in memory stay
  active until the file is valid again.
- If two tools write at once, the last valid write wins. Edit the file while
  the palette is closed to avoid confusion.

## Disabling the plugin leaves shortcuts behind

Fixed in 0.6.0. Disabling or removing the plugin clears the generated binds.
For older builds, run:

```bash
omarchy-shell apach.dropdown cleanup
```

## Drawer keyboard navigation

- `Space` or a click on the `All apps` row toggles the drawer.
- `Down` enters the drawer from the cards; arrows move by card.
- `Enter` opens the selected card; `Escape` collapses the drawer first, then
  closes the palette.
- If cards are narrower than expected, the column count adapts to the card
  width; the keyboard uses the same count.

## Collecting a bug report

Include the output of:

```bash
omarchy --version
hyprctl version
omarchy-shell apach.dropdown doctor
omarchy-shell apach.dropdown status
journalctl --user -b --no-pager | grep -i 'omarchy-dropdown\|Overlay.qml\|Service.qml'
```

Redact personal app names and paths before posting publicly.
