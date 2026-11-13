// Pure limits and helpers for bounded helpers, clipboard reads and queues.
// No QML or shell access, so every function here is covered by
// tests/bounds.test.mjs. The QML side (components/BoundedProcess.qml) applies
// these values; keeping them here makes the numeric contract testable.

// Producer caps are always one byte above the consumer cap so a payload that
// exactly fits is accepted and anything larger is detectable, never parsed as
// if it were complete.
var LIMITS = {
  clipboardBytes: 65536,
  clipboardErrBytes: 4096,
  searchChars: 200,
  configBytes: 1048576,
  stateBytes: 4194304,
  shellConfigBytes: 1048576,
  agentBytes: 65536,
  bindsBytes: 1048576,
  hyprOutputBytes: 4194304,
  helperOutBytes: 65536,
  helperErrBytes: 8192,
  queueItems: 64,
  launchArmItems: 32,
  callbackMaxAgeMs: 30000,
  stateEntries: 512,
  catalogApps: 4096
}

// UTF-8 byte length without TextEncoder: QML's JS engine has no TextEncoder,
// and a raw `.length` would undercount every non-ASCII character.
function utf8ByteLength(text) {
  var value = String(text === undefined || text === null ? "" : text)
  var bytes = 0
  for (var i = 0; i < value.length; i++) {
    var code = value.charCodeAt(i)
    if (code < 0x80) {
      bytes += 1
    } else if (code < 0x800) {
      bytes += 2
    } else if (code >= 0xd800 && code <= 0xdbff) {
      var next = i + 1 < value.length ? value.charCodeAt(i + 1) : 0
      if (next >= 0xdc00 && next <= 0xdfff) {
        bytes += 4
        i++
      } else {
        bytes += 3
      }
    } else {
      bytes += 3
    }
  }
  return bytes
}

// Wrap an argv vector so the producer itself is bounded: `timeout` enforces an
// absolute deadline and `head -c` stops stdout one byte past the consumer cap.
// stderr is left untouched here: routing it through a process-substitution
// `head` could delay it past `exited`, and the receiver already caps it on
// every chunk (`waitForEnd: false` + chunkOverflow) plus an exact final check.
// The shell script is a constant; the command and its arguments travel as
// positional parameters, so no caller value can become shell syntax. The exit
// status is the producer's (124 on timeout, 141 on SIGPIPE, 127 when the tool
// is missing), not `head`'s.
function producerCommand(argv, maxBytes, timeoutSeconds) {
  var list = []
  for (var i = 0; i < (argv || []).length; i++) list.push(String(argv[i]))
  if (list.length === 0) return []
  var cap = Math.max(1, Math.floor(Number(maxBytes) || 0)) + 1
  var seconds = Math.max(1, Math.ceil(Number(timeoutSeconds) || 2))
  return ["bash", "-c",
    "timeout -k 1 " + seconds + ' "$@" | head -c ' + cap + "; exit ${PIPESTATUS[0]}",
    "bash"].concat(list)
}

// Bounded file read without a shell: `head` opens the path directly (argv
// element, never interpolated), `timeout` bounds the helper. The consumer cap
// is one byte below the produced cap.
function fileReadCommand(path, maxBytes) {
  var cap = Math.max(1, Math.floor(Number(maxBytes) || 0)) + 1
  return ["timeout", "-k", "1", "2", "head", "-c", String(cap), String(path || "")]
}

function clipboardCommand(primary) {
  var argv = ["wl-paste", "--no-newline"]
  if (primary === true) argv.push("--primary")
  return producerCommand(argv, LIMITS.clipboardBytes, 2)
}

// Classify a file before deciding what a failed read may do. The script is
// constant and the path is a positional parameter: exit 0 readable, 1 absent,
// 2 present but unreadable. `timeout` keeps the probe bounded.
function fileStateCommand(path) {
  return ["timeout", "-k", "1", "2", "bash", "-c",
    'if [ -e "$1" ]; then if [ -r "$1" ]; then exit 0; else exit 2; fi; else exit 1; fi',
    "bash", String(path || "")]
}

// -1 = unknown (probe failed), 0 = readable, 1 = absent, 2 = unreadable.
// The probe exits non-zero for "absent" and "unreadable", so this reads the
// code even when `ok` is false; only overflow/timeout/failed start/cancel are
// treated as an unknown probe.
function fileStateFromExit(result) {
  if (!result) return -1
  if (result.overflow || result.timedOut || result.startFailed || result.canceled) return -1
  var code = Number(result.code)
  if (code === 0) return 0
  if (code === 1) return 1
  if (code === 2) return 2
  return -1
}

// A read that failed may only create defaults when the file is provably
// absent. Timeouts, overflows, failed starts, permission errors and an
// unknown probe state all keep the file untouched.
function readFailurePolicy(fileState, failure) {
  if (fileState === 1) return "absent"
  if (failure && (failure.overflow || failure.timedOut || failure.startFailed)) return "refuse"
  if (fileState === 0 || fileState === 2) return "refuse"
  return "refuse"
}

// Collect at most `limit` own keys from a parsed object. Used for state
// entries: a hostile or corrupt state file cannot grow the registry map.
function boundedKeys(source, limit) {
  var keys = []
  var dropped = 0
  if (!source || typeof source !== "object") return { keys: keys, dropped: 0 }
  var max = Math.max(1, Math.floor(Number(limit) || 1))
  for (var key in source) {
    if (!Object.prototype.hasOwnProperty.call(source, key)) continue
    if (keys.length >= max) { dropped++; continue }
    keys.push(key)
  }
  return { keys: keys, dropped: dropped }
}

// Admission test for the derived desktop-entry catalog. The service calls
// this before adding a discovered entry.
function catalogRoom(discoveredCount, ordinaryCount, limit) {
  var used = (Number(discoveredCount) || 0) + (Number(ordinaryCount) || 0)
  return used < Math.max(0, Math.floor(Number(limit) || 0))
}

// Bounded queue push: drop the oldest entries when the cap is reached so no
// producer can grow a queue without bound. `dropped` is reported so callers
// can warn once per overflow.
function pushBounded(queue, item, limit) {
  var list = (queue || []).slice()
  list.push(item)
  var max = Math.max(1, Math.floor(Number(limit) || 1))
  var dropped = 0
  while (list.length > max) {
    list.shift()
    dropped++
  }
  return { queue: list, dropped: dropped }
}

// Callbacks carry their enqueue time. A helper that never finishes (or a
// failed start) cannot leave a callback pending forever: drainers drop entries
// older than maxAgeMs and report how many were stale.
function pushCallback(queue, callback, limit, now) {
  if (typeof callback !== "function") return { queue: (queue || []).slice(), dropped: 0 }
  var at = typeof now === "number" ? now : Date.now()
  return pushBounded(queue, { fn: callback, at: at }, limit)
}

function takeFreshCallbacks(queue, now, maxAgeMs) {
  var list = queue || []
  var current = typeof now === "number" ? now : Date.now()
  var age = Math.max(0, Number(maxAgeMs) || 0)
  var callbacks = []
  var stale = 0
  for (var i = 0; i < list.length; i++) {
    var item = list[i]
    var fn = typeof item === "function" ? item : (item ? item.fn : null)
    if (typeof fn !== "function") continue
    var at = typeof item === "function" ? current : Number(item.at)
    if (isFinite(at) && age > 0 && current - at > age) {
      stale++
      continue
    }
    callbacks.push(fn)
  }
  return { callbacks: callbacks, stale: stale }
}

// Per-chunk cap decision used by BoundedProcess._watchStream. `length` is the
// UTF-16 length of the text accumulated so far; bytes >= UTF-16 units, so
// crossing this limit is certain to cross the byte cap too. Computing it per
// chunk (rather than only at stream end) is what keeps memory bounded.
function chunkOverflow(length, cap) {
  return (Number(length) || 0) > Math.max(0, Math.floor(Number(cap) || 0))
}

// Stale-result guard for async reads: a result is usable only when its tag is
// the generation that is still current. A new request, focus loss or close
// increments the generation, so a late result is discarded.
function isCurrentGeneration(tag, current) {
  if (tag === null || tag === undefined) return false
  return tag === current
}

// A single-line filter never receives embedded newlines or tabs from a paste.
function singleLine(text) {
  return String(text === undefined || text === null ? "" : text).replace(/[\r\n\t]+/g, " ")
}

// Accept only text that fits both the byte contract and the field's remaining
// characters. The caller refuses (with a notice) instead of truncating
// silently.
function insertionVerdict(text, currentLength, maxChars, maxBytes) {
  var value = singleLine(text)
  if (utf8ByteLength(value) > Math.max(0, Number(maxBytes) || 0))
    return { ok: false, reason: "tooLarge" }
  var room = Math.max(0, Number(maxChars) || 0) - Math.max(0, Number(currentLength) || 0)
  if (value.length > room) return { ok: false, reason: "tooLong" }
  return { ok: true, text: value }
}

if (typeof module !== "undefined") {
  module.exports = {
    LIMITS: LIMITS,
    utf8ByteLength: utf8ByteLength,
    producerCommand: producerCommand,
    fileReadCommand: fileReadCommand,
    clipboardCommand: clipboardCommand,
    fileStateCommand: fileStateCommand,
    fileStateFromExit: fileStateFromExit,
    readFailurePolicy: readFailurePolicy,
    boundedKeys: boundedKeys,
    catalogRoom: catalogRoom,
    pushBounded: pushBounded,
    pushCallback: pushCallback,
    takeFreshCallbacks: takeFreshCallbacks,
    chunkOverflow: chunkOverflow,
    isCurrentGeneration: isCurrentGeneration,
    singleLine: singleLine,
    insertionVerdict: insertionVerdict
  }
}
