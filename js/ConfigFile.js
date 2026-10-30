// Configuration-file helpers. Service.qml owns the FileView; these functions
// decide whether a file change is our own write, what a backup is called and
// how the file is serialized. Pure and testable.

function encode(config) {
  return JSON.stringify(config, null, 2) + "\n"
}

// A single FileView watches its own target. Without this check every save
// triggers a reload, which used to overwrite newer in-memory edits when an
// external writer raced us.
function isOwnWrite(text, lastWrite) {
  return String(text || "") === String(lastWrite || "")
}

function stamp(date) {
  var value = date instanceof Date ? date : new Date()
  function pad(n) { return n < 10 ? "0" + n : String(n) }
  return value.getFullYear() + pad(value.getMonth() + 1) + pad(value.getDate()) +
    "-" + pad(value.getHours()) + pad(value.getMinutes()) + pad(value.getSeconds())
}

function backupName(path, date) {
  var value = String(path || "")
  if (!value) return ""
  return value + ".bak-" + stamp(date)
}

// A file that is not valid JSON is never written back over the user's copy:
// Service.qml restores defaults in memory and the original stays on disk.
function looksLikeConfig(text) {
  var value = String(text || "").trim()
  if (!value) return false
  if (value.charAt(0) !== "{" || value.charAt(value.length - 1) !== "}") return false
  try { JSON.parse(value) } catch (e) { return false }
  return true
}

// Keep the five most recent backups next to the config. The command is built
// from a constant path argument, never from user text.
function pruneCommand(path) {
  return [
    "bash", "-c",
    "ls -1t -- \"$1\".bak-* 2>/dev/null | tail -n +6 | xargs -r rm --",
    "_", String(path || "")
  ]
}

if (typeof module !== "undefined") {
  module.exports = {
    encode: encode,
    isOwnWrite: isOwnWrite,
    stamp: stamp,
    backupName: backupName,
    looksLikeConfig: looksLikeConfig,
    pruneCommand: pruneCommand
  }
}
