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

// Two backups taken in the same second must never overwrite each other: a
// refused-save retry can start immediately after the previous copy. The name
// carries milliseconds and a per-process sequence, so it is unique even when
// both calls land in the same millisecond.
var backupSequence = 0

function stamp(date) {
  var value = date instanceof Date ? date : new Date()
  function pad(n, width) {
    var text = String(n)
    while (text.length < width) text = "0" + text
    return text
  }
  return value.getFullYear() + pad(value.getMonth() + 1, 2) + pad(value.getDate(), 2) +
    "-" + pad(value.getHours(), 2) + pad(value.getMinutes(), 2) + pad(value.getSeconds(), 2) +
    pad(value.getMilliseconds(), 3)
}

function backupName(path, date) {
  var value = String(path || "")
  if (!value) return ""
  backupSequence++
  return value + ".bak-" + stamp(date) + "-" + backupSequence
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

// A refused configuration can be larger than the read cap. A backup copies
// at most the same 1 MiB contract, to a deterministic `.part` file, and only
// renames it to the final name after `cp` succeeded. The temporary is removed
// on every exit path (inner timeout included), so a partial file never carries
// a final backup name. Exit 75 means "source above the backup byte cap" and
// creates nothing. The script is constant; source, target, cap and deadline
// travel as positional parameters.
var BACKUP_OVERSIZE_CODE = 75

function backupCommand(source, target, maxBytes, seconds) {
  var value = String(source || "")
  var dest = String(target || "")
  if (!value || !dest) return []
  var cap = Math.max(1, Math.floor(Number(maxBytes) || 0))
  var secs = Math.max(1, Math.ceil(Number(seconds) || 3))
  return ["bash", "-c",
    'src=$1; dest=$2; part=$3; cap=$4; secs=$5; ' +
    'cleanup() { rm -f -- "$part"; }; trap cleanup EXIT; ' +
    'case "$cap" in ""|*[!0-9]*) exit 2;; esac; ' +
    'case "$secs" in ""|*[!0-9]*) exit 2;; esac; ' +
    'size=$(stat -c %s -- "$src" 2>/dev/null) || exit 2; ' +
    'case "$size" in ""|*[!0-9]*) exit 2;; esac; ' +
    '[ "$size" -le "$cap" ] || exit 75; ' +
    'timeout -k 1 "$secs" cp -- "$src" "$part" || exit $?; ' +
    'mv -- "$part" "$dest" || exit $?; trap - EXIT',
    "bash", value, dest, dest + ".part", String(cap), String(secs)]
}

// Keep the five most recent backups next to the config. `.part` files from a
// crashed copy are excluded from that count and stale ones (older than two
// minutes) are removed; a fresh part may belong to a copy still in flight.
// The command is built from a constant path argument, never from user text.
function pruneCommand(path) {
  return [
    "bash", "-c",
    "ls -1t -- \"$1\".bak-* 2>/dev/null | grep -v '\\.part$' | tail -n +6 | xargs -r rm --; " +
      "find \"$(dirname -- \"$1\")\" -maxdepth 1 -type f " +
      "-name \"$(basename -- \"$1\").bak-*.part\" -mmin +2 -delete 2>/dev/null || true",
    "_", String(path || "")
  ]
}

if (typeof module !== "undefined") {
  module.exports = {
    encode: encode,
    isOwnWrite: isOwnWrite,
    stamp: stamp,
    backupName: backupName,
    backupCommand: backupCommand,
    BACKUP_OVERSIZE_CODE: BACKUP_OVERSIZE_CODE,
    looksLikeConfig: looksLikeConfig,
    pruneCommand: pruneCommand
  }
}
