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
| `dropdown-state.json` | User or another local tool | Window adoption, previous workspace |
| `~/.config/hypr/dropdown.lua` | User-writable Lua loaded by the compositor | Compositor code |
| IPC arguments (`showApp`, `setShortcut`, …) | Any local process | App ids, chords |
| Clipboard (PRIMARY and CLIPBOARD) | Any application on the session | Unbounded text insertion, huge payloads |

## Sinks and mitigations

- **QML text**: every `Text` uses `textFormat: Text.PlainText`. This is
  enforced by `tests/qml-security.test.mjs`, which fails CI when a `Text`
  element is added without it or when `AutoText`/`RichText` is requested.
  A title containing `<img src="…">` is displayed literally and never fetched.
- **Tooltips and controls**: `Text` is not the only sink. A stock
  `QtQuick.Controls.ToolTip` renders its `text` through an internal `Text`
  with the default `AutoText`, and so do `Button`/`Label` content items.
  Dynamic strings must use a component that sets `PlainText` (Omarchy's bar
  and panel controls do) or override `contentItem` with a `PlainText` `Text`,
  as Quay does for application names. Never put a window title, app name or
  notification body in a stock tooltip.
- **Images**: only `Quickshell.iconPath(<icon name from a desktop entry>)`.
  No URL or title ever reaches an `Image.source`.
- **Process execution**: launches use argv vectors with
  `uwsm-app`/`gtk-launch`/`xdg-terminal-exec`; the Hyprland `exec_cmd` path
  shell-quotes every argument. Generated direct binds pass the desktop app id
  through `Shortcuts.shellQuote`, so an id containing spaces, quotes or `;`
  cannot become shell syntax. The only `bash -c` is the constant config-backup
  prune command; it receives the config path as a positional argument. There
  is no `sudo`, `pkill` or `killall`.
- **Compositor Lua**: the launch preemption arms `_dropdownPending` with
  `hyprctl eval`. User-controlled values (app id, window class fragment, URL
  host, parking workspace) are passed through `Shortcuts.luaString` and only
  ever appear inside quoted Lua string literals; the eval chunk is passed as
  an argv vector, never through a shell. The compositor hook matches them with
  plain (non-pattern) `string.find`, so a desktop entry cannot turn a window
  class into a Lua pattern or code.
- **Hyprland dispatches**: addresses are normalized hex selectors, geometry is
  numeric and clamped, opacity is clamped to 0–1, and workspace/shortcut text
  goes through `luaString`. `luaString` also escapes `;`, `[` and `]` as Lua
  decimal sequences because `hyprctl --batch` splits on `;` outside brackets
  without parsing Lua; a workspace name can therefore never break the batch
  framing. State and config are treated as untrusted: managed special
  workspaces are rejected as destinations, and state adoption requires a
  non-empty window class equal to the live one.
- **Clipboard paste**: the Manage search field never runs Qt's native paste.
  A `Keys` handler on the focused `TextInput` (priority `BeforeItem`) accepts
  every `StandardKey.Paste` gesture and a `MouseArea` accepting only
  `Qt.MiddleButton` intercepts the PRIMARY selection. The read is
  `wl-paste` under `timeout -k 1 2` piped through `head -c 65537`, with the
  command and arguments passed as positional parameters to a constant bash
  script. The consumer refuses any payload above 64 KiB, a 200-character
  field cap bounds insertion, and a generation token invalidates results from
  a superseded request. Nothing reads the clipboard on open, only on an
  explicit paste. Covered by `tests/bounds.test.mjs` and
  `tests/qml-bounds.test.mjs`.
- **Helper processes**: every `Process` is wrapped in `BoundedProcess`
  (per-stream caps, absolute deadline, SIGTERM→SIGKILL, failed-start
  detection). `StdioCollector` stores the raw bytes and the text is decoded
  once, so a multi-byte character split across reads is never corrupted;
  `waitForEnd: false` makes the per-chunk cap effective before the buffer can
  grow. Both streams are also capped at the producer by a constant bash
  pipeline: `timeout -k 1` bounds the helper, stdout is piped through
  `head -c cap+1`, and stderr through a synchronous bounded reader that emits
  at most `capErr+1` bytes and drains the rest to /dev/null. The reader is a
  pipeline member, so bash cannot exit before the bounded diagnostic is
  written; a process substitution would not be waited for. Output larger than
  the cap is a hard failure, never a partial parse. Config/state/agent/shell/
  binds files are read with `timeout head -c` in argv form, so a huge or
  malicious file is refused.
- **Detached calls**: the few calls that must survive QML destruction
  (`hyprctl reload`, the detached launch/restore dispatch, the disarm `eval`,
  the startup `mkdir -p`, and the launch-preemption park) are all wrapped in a
  global `timeout -k 1 N` by `Bounds.detachedCommand` (5 s; the park 3 s).
  `Quickshell.execDetached` is called from that single site, so no finite
  detached process can run without a deadline. Output is not captured.
- **Refused files**: a failed config read is never treated as "missing". A
  bounded `test -e`/`test -r` probe decides whether defaults may be created;
  on a timeout, overflow, permission error or unknown probe state the file is
  left untouched, the configuration is marked refused and automatic writes
  are blocked. Every config backup is a bounded copy run in a
  `BoundedProcess`: an explicit save, an external-edit adoption and a rewrite
  of local edits all wait for its success before writing or adopting. The
  destination is capped at the 1 MiB config read cap; a larger source exits
  75 before creating anything (dedicated notice, barrier kept). The copy
  writes `<target>.part` and renames it atomically only on success; failure,
  timeout and a SIGKILL of the wrapper all leave no partial file, and the
  prune removes stale parts. If the backup fails, nothing is overwritten and
  the user is told; a second request during a copy is deferred to one pending
  slot, never run concurrently. A refused state file is never rewritten
  automatically; one bounded retry may recover it.
- **Writes**: `dropdown.json` (atomic, validated), its timestamped backups,
  the generated `~/.config/hypr/dropdown-binds.lua`, the state file under
  `~/.local/state/omarchy/`, and the bar placement file. The installer also
  edits `hyprland.lua` and `dropdown.lua` with a backup; plugin backups live in
  `~/.config/omarchy/plugin-backups/`, outside the plugin scan root.
- **Network**: none. The only URLs stored are the web-app addresses the user
  configures or a desktop entry exposes; every write path applies
  `Model.isSafeUrl` and restricts them to plain `http(s)` with no quotes,
  whitespace or control characters. App keys are normalized to one printable
  lowercase character, and `__proto__`/`constructor`/`prototype` app ids are
  rejected so a config cannot pollute `Object.prototype`.

## Checklist for a change

1. Does it introduce a new untrusted string? Where is it rendered? If it is a
   `Text`, `PlainText` is mandatory; check tooltips, buttons and labels too.
   If it is an `Image`, it must not be a URL.
2. Does it pass a value to a process or a Hyprland dispatcher? Use an argv
   vector or `luaString`/`windowSelector`; never interpolate into a shell.
3. Does it write a file? Keep it under `~/.config/omarchy`, `~/.config/hypr`
   or the Omarchy state dir, write atomically, and validate before writing.
4. Does it add an IPC method? Validate types and reject unknown ids; never
   return file contents or tokens.
5. Run `node --test tests/*.test.mjs`; the QML security test must pass.
6. Update this page when a new input or sink appears.

## Accepted residual limits

- The producer-side stderr reader drains what it does not deliver to
  /dev/null, so a helper that writes an unbounded amount of stderr still
  consumes CPU/IO while it runs; only the bytes reaching Qt are capped at
  `capErr+1`.
- A helper that leaves a child inheriting stdout or stderr keeps the
  wrapper's pipeline open. `timeout` only signals the direct child, so this
  can surface as a false timeout (124) after the deadline, or as 137/9 when
  the QML SIGKILL escalation ends the wrapper first. Callers branch on the
  `timedOut` flag where it matters; the clipboard path also maps code 124.
- The service can only retire an orphan, not reap it: a daemonizing helper
  that detaches from the process group is outside the plugin's control.
- The initial configuration load adopts an existing file without a backup:
  nothing is overwritten at startup, so there is nothing to preserve. Every
  later write or external-change adoption takes the bounded backup first.
- The launch-preemption park is detached so it survives QML destruction. Like
  every detached call it is bounded by `timeout -k 1 3`; its output is not
  captured, and the client poll re-parks the window when the dispatch did not
  apply. Detached calls are not escalated by the QML deadline, but the
  `timeout` wrapper still terminates a hung process.
- A config backup above 1 MiB is refused rather than copied, so an oversized
  (typically unreadable) configuration has no backup file; the source is left
  intact and the write barrier stays in place.
- `FileView` is notification/write only; its internal `watchChanges`
  metadata handling is outside the plugin's control.
- No live Quickshell session was used for automated paste/process tests; the
  Qt signal wiring is covered by static invariants and real producer streams,
  not by a running shell.

## History

- **0.8.3** — detached calls and backup bytes. Every finite detached call
  (reload, detached launch/restore dispatch, disarm eval, startup mkdir) is
  wrapped in a global `timeout -k 1 5`, with the preemption park at 3 s; there
  is a single `execDetached` site. Config backups cap the destination at the
  1 MiB read cap, write a deterministic `.part`, rename atomically only on
  success, and remove the part on failure/timeout/SIGKILL; an oversized source
  exits 75 without creating anything. The prune excludes parts from the five
  kept backups and removes stale ones. Reported in the marketplace review
  (`omacom/omarchy-plugin-marketplace#14610`).
- **0.8.2** — process-resource prerequisites. stderr is now bounded at the
  producer by a synchronous pipeline member (a delayed `head` cannot outlive
  `exited`, and the excess is drained instead of SIGPIPE-killing the helper),
  with the per-chunk watcher and final UTF-8 check kept as defence in depth.
  Every config backup — external-edit adoption, local-edit rewrite and
  refused-file replacement — is a bounded, awaited `cp`; the write or adoption
  happens only after it succeeds. A failed adoption backup restores the
  refusal barrier so no automatic save can overwrite the external file; a
  save requested during another copy is retained, but not replayed after a
  refused-write completion that already included it. Backup names carry
  milliseconds and a per-process sequence so rapid copies never overwrite
  each other. Busy
  reveal batches are queued in a bounded FIFO and run through the bounded
  wrapper instead of a detached fallback (the launch-preemption park remains
  the one deliberate, `timeout -k 1 3`-bounded exception); every batch settles
  its callback exactly once. Reported in the marketplace
  review (`omacom/omarchy-plugin-marketplace#14610`).
- **0.8.1** — bounded paste and bounded helpers. The Manage search field
  intercepts all keyboard paste gestures and middle-click PRIMARY; clipboard
  reads are producer- and consumer-bounded (64 KiB, 2 s) with stale-request
  cancellation. All external helpers gained deadlines, output caps,
  SIGTERM→SIGKILL escalation and failed-start recovery; streams are decoded
  once from a complete bounded buffer (a per-chunk decoder could corrupt
  split UTF-8 characters), and refused config/state files are never
  overwritten automatically. Files are read through bounded producers and
  queues/collections have explicit caps. Reported in the marketplace review
  (`omacom/omarchy-plugin-marketplace#14610`).
- **0.7.14** — audit hardening. `luaString` escapes batch separators
  (`;[]`) so a workspace name cannot inject a `hyprctl --batch` dispatch;
  generated bind commands shell-quote the desktop app id; config/state reject
  `__proto__`-style ids and state adoption requires a matching window class;
  existing-window adoption no longer trusts a page-controlled title; URL
  writes all pass `isSafeUrl`; `doctorRedacted` masks every identifier; app
  keys are one printable lowercase character. The launch preemption itself
  adds the compositor Lua sink (`hyprctl eval` arming `_dropdownPending`);
  every user-controlled value is a quoted Lua string literal, matching uses
  plain `string.find`, and the title fallback is only armed when the app has
  no class.
- **0.7.11** — window titles and all dynamic text forced to
  `Text.PlainText`. Reported in the
  [marketplace review](https://github.com/omacom/omarchy-plugin-marketplace/issues/13532).
