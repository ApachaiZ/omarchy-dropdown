// A Process wrapper with hard resource and lifetime bounds.
//
// Quickshell's Process has no timeout, no output cap and no kill escalation;
// a missing binary never emits `exited`, only `runningChanged`. This component
// owns those guarantees once so every helper in the plugin shares them:
//
// - stdout/stderr are captured by StdioCollector, which stores the raw bytes
//   and decodes them once into a QString. This is deliberate: splitting the
//   stream into chunks with SplitParser and decoding each chunk separately
//   corrupts a multi-byte UTF-8 character that straddles two reads.
// - The byte caps are enforced before any caller parses the text. `producerBound`
//   also wraps the command so it stops itself: `timeout -k 1 N` plus
//   `head -c cap+1`. A collector watcher terminates a stream whose text
//   exceeds the cap; the final result recomputes the exact UTF-8 byte length
//   and marks `overflow`. A partial payload is never handed to a parser as if
//   it were complete.
// - stderr is bounded by the same collector watch plus the exact final check.
//   Its producer is not wrapped (stderr has no byte-preserving pipeline), so a
//   runaway stderr is killed as soon as the cap is crossed; at most one
//   in-flight chunk can overshoot.
// - the QML deadline sends SIGTERM, then SIGKILL 500 ms later, and finally
//   settles by force if the process still never reports `exited`.
// - a failed start (binary missing) is detected through `runningChanged`.
// - exactly one `finished(result)` is emitted per run with
//   { ok, code, out, err, overflow, timedOut, startFailed, canceled, tag }.
// - `cancel()` is idempotent; a late result after cancellation is ignored by
//   the caller's generation/tag check.
// - `start()` while a run is active supersedes it: the request goes into a
//   bounded FIFO (8 entries) and the running process is terminated. A request
//   started from an `onFinished` handler begins immediately; any queued
//   request runs after it, so a handler cannot silently drop the queue. When
//   the FIFO is full, `start()` returns false instead of losing a request.

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
  readonly property int maxQueue: 8

  readonly property bool running: _active

  signal finished(var result)

  property bool _active: false
  property bool _settled: false
  property bool _started: false
  property bool _overflow: false
  property bool _timedOut: false
  property bool _startFailed: false
  property bool _canceled: false
  property var _tag: null
  property var _queue: []

  function start(argv, tag) {
    var list = []
    for (var i = 0; i < (argv || []).length; i++) list.push(String(argv[i]))
    if (list.length === 0) return false
    var label = tag === undefined ? null : tag
    if (_active) {
      if (_queue.length >= maxQueue) {
        console.warn("omarchy-dropdown: BoundedProcess queue full; refusing a request")
        return false
      }
      _queue.push({ command: list, tag: label })
      // A newer request supersedes the running one: terminate it and let the
      // queue start once the process has actually stopped. Its result is
      // marked canceled and ignored by the caller's tag check.
      if (!_canceled) {
        _canceled = true
        _terminate()
      }
      return true
    }
    _begin(list, label)
    return true
  }

  function cancel() {
    // A cancellation (focus loss, close, watchdog) also drops queued requests:
    // a stale clipboard read must not start after the field is gone.
    _queue = []
    if (!_active || _settled) return
    _canceled = true
    _terminate()
  }

  // Alias used by callers that think in terms of a watchdog.
  function terminate() {
    cancel()
  }

  function _begin(list, tag) {
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

  function _collectorText(collector) {
    return String(collector ? collector.text || "" : "")
  }

  // Cheap per-chunk guard. Reading `text.length` is O(1); an exact UTF-8 byte
  // count is only computed once, at the end. Because bytes >= UTF-16 units, a
  // text longer than the cap is certainly over the byte cap; a shorter text
  // may still be over and is caught by the exact check at finalize.
  function _watchStream(collector, cap) {
    if (_settled || _overflow) return
    var text = _collectorText(collector)
    if (text.length > cap) {
      _overflow = true
      _terminate()
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
    var outText = _collectorText(outCollector)
    var errText = _collectorText(errCollector)
    if (!_overflow && Bounds.utf8ByteLength(outText) > maxOutBytes) _overflow = true
    if (!_overflow && Bounds.utf8ByteLength(errText) > maxErrBytes) _overflow = true
    var exitCode = Number(code)
    if (!isFinite(exitCode)) exitCode = -1
    var result = {
      ok: !_overflow && !_timedOut && !_startFailed && !_canceled && exitCode === 0,
      code: _startFailed ? -1 : exitCode,
      out: outText,
      err: errText,
      overflow: _overflow,
      timedOut: _timedOut,
      startFailed: _startFailed,
      canceled: _canceled,
      tag: _tag
    }
    finished(result)
    _beginNext()
  }

  // FIFO: a handler that started a run from `onFinished` is already active, so
  // the next queued request waits for that run instead of being dropped.
  function _beginNext() {
    if (_active || _queue.length === 0) return
    var item = _queue.shift()
    _begin(item.command, item.tag)
  }

  Process {
    id: proc
    stdout: StdioCollector {
      id: outCollector
      waitForEnd: true
      onDataChanged: root._watchStream(outCollector, root.maxOutBytes)
    }
    stderr: StdioCollector {
      id: errCollector
      waitForEnd: true
      onDataChanged: root._watchStream(errCollector, root.maxErrBytes)
    }
    onStarted: function() { root._started = true }
    onExited: function(code, status) {
      // Defer one event-loop turn so any final readyRead data reaches the
      // collectors before the buffer is decoded.
      Qt.callLater(function() { root._finalize(code) })
    }
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
