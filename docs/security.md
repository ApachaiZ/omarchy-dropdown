# Security review

This is the threat model behind Dropdown and the checklist used before a
release. It exists because the 0.7.10 marketplace review found a real bug that
a policy-only review had missed: window titles were rendered as QML rich text.

## Untrusted inputs

| Input | Origin | Risk |
| --- | --- | --- |
| Window title / class / initial class | Any application, including a remote web page | Text rendered by the shell, class matching |
| Window workspace, size, address | Hyprland | Dispatch targets, geometry |
| Desktop entries | Local files, but user-writable | Commands, names, icons |
| `dropdown.json` | User or another local tool | URLs, geometry, shortcuts |
| IPC arguments (`showApp`, `setShortcut`, …) | Any local process | App ids, chords |

## Sinks and mitigations

- **QML text**: every `Text` uses `textFormat: Text.PlainText`. This is
  enforced by `tests/qml-security.test.mjs`, which fails CI when a `Text`
  element is added without it or when `AutoText`/`RichText` is requested.
  A title containing `<img src="…">` is displayed literally and never fetched.
- **Images**: only `Quickshell.iconPath(<icon name from a desktop entry>)`.
  No URL or title ever reaches an `Image.source`.
- **Process execution**: launches use argv vectors with
  `uwsm-app`/`gtk-launch`/`xdg-terminal-exec`; the Hyprland `exec_cmd` path
  shell-quotes every argument. There is no `eval`, `sh -c`, `sudo`, `pkill`
  or `killall` in the plugin.
- **Hyprland dispatches**: addresses are normalized hex selectors, geometry is
  numeric and clamped, workspace and shortcut text goes through `luaString`.
- **Writes**: only `dropdown.json` (atomic, validated), the generated
  `dropdown-binds.lua`, the local state file, and a bar placement file. No
  user file outside `~/.config/omarchy` is modified by the running plugin.
- **Network**: none. The only URLs stored are the web-app addresses the user
  configures; `Model.isSafeUrl` restricts them to plain `http(s)` with no
  quotes, whitespace or control characters.

## Checklist for a change

1. Does it introduce a new untrusted string? Where is it rendered? If it is a
   `Text`, `PlainText` is mandatory; if it is an `Image`, it must not be a URL.
2. Does it pass a value to a process or a Hyprland dispatcher? Use an argv
   vector or `luaString`/`windowSelector`; never interpolate into a shell.
3. Does it write a file? Keep it under `~/.config/omarchy` or the state dir,
   write atomically, and validate before writing.
4. Does it add an IPC method? Validate types and reject unknown ids; never
   return file contents or tokens.
5. Run `node --test tests/*.test.mjs`; the QML security test must pass.
6. Update this page when a new input or sink appears.

## History

- **0.7.11** — window titles and all dynamic text forced to
  `Text.PlainText`. Reported in the
  [marketplace review](https://github.com/omacom/omarchy-plugin-marketplace/issues/13532).
