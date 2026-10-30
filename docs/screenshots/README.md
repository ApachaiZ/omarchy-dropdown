# Screenshots

Captured on one monitor on an empty workspace, with no other application
visible. Full monitor height is cropped to the card area; the kitty capture
keeps the full screen so the empty workspace is visible. The regular captures
use only the three standard Omarchy defaults (kitty, Agent, Fichiers).

| View | Card |
| --- | --- |
| Palette | `palette-card.png` |
| All-apps drawer | `drawer-card.png` |
| Manage applications | `manage-card.png` |
| Preview | `preview-card.png` |
| Size, position, tabs, behaviour | `settings-card.png` |
| Animations | `animations-card.png` |
| Shortcuts | `shortcuts-card.png` |
| Bar placement | `bar-placement-card.png` |
| Help | `help-card.png` |
| kitty in the dropdown | `kitty.png` (full) / `kitty-card.png` |

`cards-contact.png` shows the palette screens together.

Regenerate them with `scripts/screenshots.sh`. It backs up your configuration,
state and generated binds, installs a standard three-app config, captures the
views on an empty workspace, then restores everything via its `EXIT` trap.

The Manage screenshot is filtered to the three standard system defaults
(kitty, Agent, Fichiers) so no personal web app is shown. The footer shows the
`D Direct` action used to bind a direct Hyprland shortcut, and the Settings
capture includes the `Top cards` row added in 0.6.0.
