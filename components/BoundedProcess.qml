// A Process wrapper with hard resource and lifetime bounds.
//
// Quickshell's Process has no timeout, no output cap and no kill escalation;
// a missing binary never emits `exited`, only `runningChanged`. This component
// owns those guarantees once so every helper in the plugin shares them:
//
// - stdout/stderr are collected incrementally and capped separately. A stream
//   that exceeds its cap is terminated and reported as `overflow`; the partial
//   payload is never handed to a parser as if it were complete.
// - with `producerBound` the command is wrapped in a constant bash script that
//   pipes it through `timeout -k 1 N` and `head -c cap+1`, so the producer
//   itself stops at the deadline and the byte cap even if it ignores SIGTERM.
// - the QML deadline sends SIGTERM, then SIGKILL 500 ms later, and finally
//   settles by force if the process still never reports `exited`.
// - a failed start (binary missing) is detected through `runningChanged`.
// - exactly one `finished(result)` is emitted per run with
//   { ok, code, out, err, overflow, timedOut, startFailed, canceled, tag }.
// - `cancel()` is idempotent; a late result after cancellation is ignored by
//   the caller's generation/tag check.
// - a run requested while the helper is still terminating is queued and
//   started once the previous process has actually stopped.

import QtQuick
import Quickshell.Io
import "../js/Bounds.js" as Bounds

Item {
  id: root
  visible: false
  width: 0
  height: 0

  // Configured per instance by the caller.
  property int maxOutBytes: Bounds.LIMITS.helperOutBytes
  property int maxErrBytes: Bounds.LIMITS.helperErrBytes
  property int timeoutMs: 4000
  property bool producerBound: true
  property int producerTimeoutSeconds: 2

  readonly property bool running: _active

  signal finished(var result)

  property bool _active: false
  property bool _settled: false
  property bool _started: false
  property bool _overflow: false
  property bool _timedOut: false
  property bool _startFailed: false
  property bool _canceled: false
  property string _out: ""
  property int _outBytes: 0
  property string _err: ""
  property int _errBytes: 0
  property var _tag: null
  property var _next: null

  function start(argv, tag) {
    var list = []
    for (var i = 0; i < (argv || []).length; i++) list.push(String(argv[i]))
    if (list.length === 0) return false
    var label = tag === undefined ? null : tag
    if (_active) {
      // A newer request supersedes the current run. Queue it behind the
      // termination so the same QProcess object is never started twice.
      _next = { command: list, tag: label }
      cancel()
      return true
    }
    _begin(list, label)
    return true
  }

  function cancel() {
    if (!_active || _settled) return
    _canceled = true
    _terminate()
  }

  // Alias used by callers that think in terms of a watchdog.
  function terminate() {
    cancel()
  }

  function _begin(list, tag) {
    _out = ""
    _outBytes = 0
    _err = ""
    _errBytes = 0
    _overflow = false
    _timedOut = false
    _startFailed = false
    _canceled = false
    _settled = false
    _started = false
    _tag = tag
    _active = true
    proc.command = producerBound
      ? Bounds.producerCommand(list, maxOutBytes, producerTimeoutSeconds)
      : list
    // Arm the deadline before starting: a failed start can settle
    // synchronously from `runningChanged`, and the deadline must not be
    // restarted on an already-settled run afterwards.
    deadline.interval = Math.max(100, Number(timeoutMs) || 0)
    deadline.restart()
    proc.running = true
  }

  function _append(stream, data) {
    if (_settled || _overflow || _canceled) return
    var chunk = String(data === undefined || data === null ? "" : data)
    var bytes = Bounds.utf8ByteLength(chunk)
    if (stream === "out") {
      if (_outBytes + bytes > maxOutBytes) {
        _overflow = true
        _terminate()
        return
      }
      _outBytes += bytes
      _out += chunk
    } else {
      if (_errBytes + bytes > maxErrBytes) {
        _overflow = true
        _terminate()
        return
      }
      _errBytes += bytes
      _err += chunk
    }
  }

  function _terminate() {
    if (!_active || _settled) return
    if (proc.running) {
      proc.signal(15)
      killTimer.restart()
    } else {
      _finalize(-1)
    }
  }

  function _finalize(code) {
    if (_settled) return
    _settled = true
    deadline.stop()
    killTimer.stop()
    forceTimer.stop()
    _active = false
    var exitCode = Number(code)
    if (!isFinite(exitCode)) exitCode = -1
    var result = {
      ok: !_overflow && !_timedOut && !_startFailed && !_canceled && exitCode === 0,
      code: _startFailed ? -1 : exitCode,
      out: _out,
      err: _err,
      overflow: _overflow,
      timedOut: _timedOut,
      startFailed: _startFailed,
      canceled: _canceled,
      tag: _tag
    }
    var queued = _next
    _next = null
    finished(result)
    // A handler may have started a fresh run already; do not overwrite it.
    if (queued && !_active) _begin(queued.command, queued.tag)
  }

  Process {
    id: proc
    stdout: SplitParser {
      splitMarker: ""
      onRead: function(data) { root._append("out", data) }
    }
    stderr: SplitParser {
      splitMarker: ""
      onRead: function(data) { root._append("err", data) }
    }
    onStarted: function() { root._started = true }
    onExited: function(code, status) { root._finalize(code) }
    onRunningChanged: {
      // QProcess failed to start: it never emits `exited`, so settling only
      // on onExited would block the caller forever.
      if (proc.running || !root._active || root._settled) return
      if (root._started) return
      root._startFailed = true
      root._finalize(-1)
    }
  }

  Timer {
    id: deadline
    repeat: false
    onTriggered: {
      root._timedOut = true
      root._terminate()
    }
  }

  Timer {
    id: killTimer
    interval: 500
    repeat: false
    onTriggered: {
      if (proc.running) proc.signal(9)
      forceTimer.restart()
    }
  }

  // SIGKILL should always end the process, but if the compositor or a stuck
  // child keeps Quickshell from reporting `exited`, settle anyway so queues,
  // callbacks and timers can move on.
  Timer {
    id: forceTimer
    interval: 700
    repeat: false
    onTriggered: {
      if (proc.running) proc.running = false
      root._finalize(-1)
    }
  }
}
