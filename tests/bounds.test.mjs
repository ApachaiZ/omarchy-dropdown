import test from "node:test"
import assert from "node:assert/strict"
import { createRequire } from "node:module"
import { spawnSync, spawn } from "node:child_process"
import { mkdtempSync, mkdirSync, writeFileSync, chmodSync, rmSync, readFileSync, existsSync, utimesSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

const require = createRequire(import.meta.url)
const Bounds = require("../js/Bounds.js")
const Model = require("../Model.js")
const ConfigFile = require("../js/ConfigFile.js")

test("utf8ByteLength counts UTF-8 bytes, not UTF-16 units", () => {
  const samples = ["", "abc", "é", "€", "😀", "aé€😀z", "\uD800", "é\uD800é"]
  for (const sample of samples) {
    assert.equal(Bounds.utf8ByteLength(sample), Buffer.byteLength(sample, "utf8"), sample)
  }
})

test("producerCommand keeps the script constant and the command in argv", () => {
  const command = Bounds.producerCommand(["wl-paste", "--no-newline; rm -rf /"], 65536, 2, 4096)
  assert.equal(command[0], "bash")
  assert.equal(command[1], "-c")
  // Both streams are bounded at the producer. The stderr reader is a
  // synchronous pipeline member (not a process substitution, which bash does
  // not wait for) and drains past its cap so the producer is not killed.
  assert.match(command[2], /set -o pipefail/)
  assert.match(command[2], /\| head -c 65537$/)
  assert.match(command[2], /head -c 4097 >&2/)
  assert.match(command[2], /cat > \/dev\/null/)
  assert.equal(/\(>|>\)\(/.test(command[2]), false)
  assert.equal(command[3], "bash")
  assert.deepEqual(command.slice(4), ["wl-paste", "--no-newline; rm -rf /"])
})

test("producerCommand refuses empty commands and clamps the caps", () => {
  assert.deepEqual(Bounds.producerCommand([], 100, 2), [])
  const command = Bounds.producerCommand(["true"], -5, 0)
  assert.match(command[2], /head -c 2$/)
  assert.match(command[2], /head -c 2 >&2/)
  assert.match(command[2], /timeout -k 1 2 /)
  // An omitted stderr cap falls back to the stdout cap, never unbounded.
  assert.match(command[2], /head -c 2 >&2/)
  const explicit = Bounds.producerCommand(["true"], 100, 2, 0)
  assert.match(explicit[2], /head -c 2 >&2/)
})

test("fileReadCommand bounds the file producer without a shell", () => {
  const command = Bounds.fileReadCommand("/tmp/a b;$(x).json", 1048576)
  assert.deepEqual(command, ["timeout", "-k", "1", "2", "head", "-c", "1048577", "/tmp/a b;$(x).json"])
})

test("clipboardCommand adds --primary only for the PRIMARY selection", () => {
  const normal = Bounds.clipboardCommand(false)
  const primary = Bounds.clipboardCommand(true)
  assert.deepEqual(normal.slice(4), ["wl-paste", "--no-newline"])
  assert.deepEqual(primary.slice(4), ["wl-paste", "--no-newline", "--primary"])
  assert.equal(normal[2], primary[2])
})

test("an automatic save is blocked while the config is refused", () => {
  // After a failed adoption backup the service keeps configRefused true, so
  // recordUse/ensureKeys/normalizeConfig cannot overwrite an unbacked file.
  assert.equal(Bounds.configSaveAction(true, false), "blocked")
  assert.equal(Bounds.configSaveAction(true, undefined), "blocked")
  // Only an explicit user save retries the bounded backup first.
  assert.equal(Bounds.configSaveAction(true, true), "backup")
  assert.equal(Bounds.configSaveAction(false, false), "write")
  assert.equal(Bounds.configSaveAction(false, true), "write")
})

test("pushBounded caps a queue and drops the oldest entries", () => {
  let queue = []
  let dropped = 0
  for (let i = 0; i < 10; i++) {
    const pushed = Bounds.pushBounded(queue, i, 4)
    queue = pushed.queue
    dropped += pushed.dropped
  }
  assert.deepEqual(queue, [6, 7, 8, 9])
  assert.equal(dropped, 6)
})

test("pushCallback stamps entries and takeFreshCallbacks drops stale ones", () => {
  let queue = []
  const calls = []
  queue = Bounds.pushCallback(queue, () => calls.push("old"), 4, 1000).queue
  queue = Bounds.pushCallback(queue, () => calls.push("new"), 4, 9000).queue
  const taken = Bounds.takeFreshCallbacks(queue, 10000, 5000)
  assert.equal(taken.stale, 1)
  assert.equal(taken.callbacks.length, 1)
  taken.callbacks[0]()
  assert.deepEqual(calls, ["new"])
})

test("insertionVerdict refuses oversized and overflowing pastes", () => {
  assert.deepEqual(Bounds.insertionVerdict("a\r\nb\tc", 0, 200, 65536),
    { ok: true, text: "a b c" })
  assert.equal(Bounds.insertionVerdict("x".repeat(65537), 0, 200, 65536).reason, "tooLarge")
  assert.equal(Bounds.insertionVerdict("x".repeat(10), 195, 200, 65536).reason, "tooLong")
  assert.deepEqual(Bounds.insertionVerdict("x".repeat(5), 195, 200, 65536),
    { ok: true, text: "xxxxx" })
})

test("isCurrentGeneration discards results from superseded requests", () => {
  assert.equal(Bounds.isCurrentGeneration(3, 3), true)
  assert.equal(Bounds.isCurrentGeneration(2, 3), false)
  assert.equal(Bounds.isCurrentGeneration(null, 3), false)
  assert.equal(Bounds.isCurrentGeneration(undefined, 3), false)
})

test("singleLine keeps filter text on one line", () => {
  assert.equal(Bounds.singleLine("a\nb\r\nc\td"), "a b c d")
})

test("validateConfig caps the number of app entries", () => {
  const apps = {}
  for (let i = 0; i < Model.MAX_CONFIG_APPS + 40; i++) {
    apps["app." + i] = { enabled: true, key: "a" }
  }
  const result = Model.validateConfig(JSON.stringify({ schemaVersion: 1, apps }))
  // DEFAULT_CONFIG carries three system entries; the cap applies to file ones.
  assert.equal(Object.keys(result.config.apps).length, Model.MAX_CONFIG_APPS + 3)
  assert.ok(result.warnings.some((warning) => /Too many app entries/.test(warning)))
})

// ---- Real producer bound, through the exact command the plugin uses. ----
// A fake `wl-paste` is placed first in PATH; the user's clipboard is never
// touched and no Quickshell instance is involved.

function withFakeWlPaste(script, run) {
  const dir = mkdtempSync(join(tmpdir(), "dropdown-bounds-"))
  const tool = join(dir, "wl-paste")
  writeFileSync(tool, "#!/bin/sh\n" + script + "\n")
  chmodSync(tool, 0o755)
  try {
    return run({ ...process.env, PATH: dir + ":" + process.env.PATH })
  } finally {
    rmSync(dir, { recursive: true, force: true })
  }
}

function runClipboardProducer(env) {
  const command = Bounds.clipboardCommand(false)
  const started = Date.now()
  const result = spawnSync(command[0], command.slice(1), {
    env,
    timeout: 15000,
    encoding: null
  })
  return { ...result, elapsed: Date.now() - started }
}

test("producer bound truncates a 1 MiB clipboard to cap+1 bytes", () => {
  withFakeWlPaste("head -c 1048576 /dev/zero | tr '\\0' a", (env) => {
    const result = runClipboardProducer(env)
    assert.equal(result.stdout.length, Bounds.LIMITS.clipboardBytes + 1)
    assert.notEqual(result.status, 0, "SIGPIPE from head must not look like success")
    assert.ok(Bounds.utf8ByteLength(result.stdout.toString("utf8")) > Bounds.LIMITS.clipboardBytes)
  })
})

test("producer bound accepts a small clipboard and preserves its status", () => {
  withFakeWlPaste("printf 'hello world'", (env) => {
    const result = runClipboardProducer(env)
    assert.equal(result.status, 0)
    assert.equal(result.stdout.toString("utf8"), "hello world")
  })
})

test("producer bound times out a clipboard tool that never finishes", () => {
  withFakeWlPaste("sleep 30", (env) => {
    const result = runClipboardProducer(env)
    assert.equal(result.status, 124)
    assert.equal(result.stdout.length, 0)
    assert.ok(result.elapsed < 8000, "timeout must fire near the 2 s deadline")
  })
})

test("producer bound reports a failing clipboard tool", () => {
  withFakeWlPaste("exit 3", (env) => {
    const result = runClipboardProducer(env)
    assert.equal(result.status, 3)
    assert.equal(result.stdout.length, 0)
  })
})

test("producer bound reports a missing clipboard tool", () => {
  const command = Bounds.producerCommand(["dropdown-missing-tool-xyz"], 65536, 2)
  const result = spawnSync(command[0], command.slice(1), { timeout: 10000, encoding: null })
  assert.equal(result.status, 127)
  assert.equal(result.stdout.length, 0)
})

// A multibyte character straddling the boundary between two reads is the
// defect a per-chunk decoder produces: each half becomes U+FFFD. Decoding the
// complete bounded buffer must keep the character intact, while the exact
// byte cap still rejects a payload one byte too large.
test("a multibyte UTF-8 character on the read boundary survives whole-buffer decoding", () => {
  const dir = mkdtempSync(join(tmpdir(), "dropdown-utf8-"))
  try {
    const prefix = Buffer.alloc(65533, 0x61) // 'a'
    const euro = Buffer.from("€", "utf8")
    const payload = Buffer.concat([prefix, euro])
    assert.equal(payload.length, 65536)
    writeFileSync(join(dir, "payload"), payload)
    writeFileSync(join(dir, "wl-paste"), "#!/bin/sh\ncat \"$(dirname \"$0\")/payload\"\n")
    chmodSync(join(dir, "wl-paste"), 0o755)
    const result = runClipboardProducer({ ...process.env, PATH: dir + ":" + process.env.PATH })
    assert.equal(result.status, 0)
    assert.equal(result.stdout.length, 65536)
    const whole = result.stdout.toString("utf8")
    assert.equal(whole.includes("�"), false)
    assert.equal(Bounds.utf8ByteLength(whole), 65536)
    assert.ok(Bounds.utf8ByteLength(whole) <= Bounds.LIMITS.clipboardBytes)
    // Same bytes decoded per chunk, with the split inside the euro sign.
    const chunked = result.stdout.subarray(0, 65534).toString("utf8") +
      result.stdout.subarray(65534).toString("utf8")
    assert.ok(chunked.includes("�"), "the regression fixture must corrupt chunked decoding")
  } finally {
    rmSync(dir, { recursive: true, force: true })
  }
})

test("producer cap at a multibyte boundary yields overflow without replacement characters", () => {
  const dir = mkdtempSync(join(tmpdir(), "dropdown-utf8-"))
  try {
    const prefix = Buffer.alloc(65534, 0x61)
    const euro = Buffer.from("€", "utf8") // bytes 65534..65536, fully inside cap+1
    const suffix = Buffer.alloc(4465, 0x62)
    writeFileSync(join(dir, "payload"), Buffer.concat([prefix, euro, suffix]))
    writeFileSync(join(dir, "wl-paste"), "#!/bin/sh\ncat \"$(dirname \"$0\")/payload\"\n")
    chmodSync(join(dir, "wl-paste"), 0o755)
    const result = runClipboardProducer({ ...process.env, PATH: dir + ":" + process.env.PATH })
    assert.equal(result.stdout.length, Bounds.LIMITS.clipboardBytes + 1)
    // The producer may finish before head closes the pipe (status 0) or die of
    // SIGPIPE (141). The overflow verdict comes from the exact byte length,
    // not from the producer's exit code.
    const text = result.stdout.toString("utf8")
    assert.equal(text.includes("�"), false)
    assert.ok(Bounds.utf8ByteLength(text) > Bounds.LIMITS.clipboardBytes)
  } finally {
    rmSync(dir, { recursive: true, force: true })
  }
})

test("readFailurePolicy only creates defaults for a provably absent file", () => {
  // 124 from the producer's timeout, with the file still readable.
  assert.equal(Bounds.readFailurePolicy(0, { code: 124 }), "refuse")
  assert.equal(Bounds.readFailurePolicy(0, { overflow: true }), "refuse")
  assert.equal(Bounds.readFailurePolicy(0, { startFailed: true }), "refuse")
  assert.equal(Bounds.readFailurePolicy(2, { code: 1 }), "refuse")
  assert.equal(Bounds.readFailurePolicy(-1, { code: 1 }), "refuse")
  assert.equal(Bounds.readFailurePolicy(1, { code: 1 }), "absent")
  assert.equal(Bounds.readFailurePolicy(1, { timedOut: true }), "absent")
  // The probe maps its own exit codes, and only a failed/overflowing probe is
  // unknown. Exit 1 and 2 are meaningful even though `ok` is false.
  assert.equal(Bounds.fileStateFromExit({ ok: true, code: 0 }), 0)
  assert.equal(Bounds.fileStateFromExit({ ok: false, code: 1 }), 1)
  assert.equal(Bounds.fileStateFromExit({ ok: false, code: 2 }), 2)
  assert.equal(Bounds.fileStateFromExit({ ok: false, code: 0 }), 0)
  assert.equal(Bounds.fileStateFromExit({ ok: false, code: 0, timedOut: true }), -1)
  assert.equal(Bounds.fileStateFromExit({ ok: false, code: 1, startFailed: true }), -1)
  assert.equal(Bounds.fileStateFromExit({ ok: false, code: 7 }), -1)
})

test("fileStateCommand probes existence and readability with a constant script", () => {
  const command = Bounds.fileStateCommand("/tmp/dropdown a;$(x).json")
  assert.deepEqual(command.slice(0, 6), ["timeout", "-k", "1", "2", "bash", "-c"])
  assert.match(command[6], /\[ -e "\$1" \]/)
  assert.match(command[6], /\[ -r "\$1" \]/)
  assert.equal(command[7], "bash")
  assert.equal(command[8], "/tmp/dropdown a;$(x).json")
})

test("fileStateCommand distinguishes readable, absent and unreadable files", () => {
  if (typeof process.getuid === "function" && process.getuid() === 0)
    return // root can read a mode-000 file; the probe would report 0
  const dir = mkdtempSync(join(tmpdir(), "dropdown-stat-"))
  try {
    const file = join(dir, "dropdown.json")
    const command = Bounds.fileStateCommand(file)
    const run = () => spawnSync(command[0], command.slice(1), { timeout: 10000, encoding: null })
    writeFileSync(file, "{}")
    assert.equal(run().status, 0)
    chmodSync(file, 0o000)
    assert.equal(run().status, 2)
    rmSync(file)
    assert.equal(run().status, 1)
  } finally {
    rmSync(dir, { recursive: true, force: true })
  }
})

test("boundedKeys caps state entries and reports dropped keys", () => {
  const apps = {}
  for (let i = 0; i < 600; i++) apps["app." + i] = { address: "0x1" }
  const bounded = Bounds.boundedKeys(apps, Bounds.LIMITS.stateEntries)
  assert.equal(bounded.keys.length, Bounds.LIMITS.stateEntries)
  assert.equal(bounded.dropped, 600 - Bounds.LIMITS.stateEntries)
  assert.deepEqual(Bounds.boundedKeys(null, 10), { keys: [], dropped: 0 })
})

test("catalogRoom stops admitting entries at the catalog limit", () => {
  assert.equal(Bounds.catalogRoom(0, 0, 4), true)
  assert.equal(Bounds.catalogRoom(2, 1, 4), true)
  assert.equal(Bounds.catalogRoom(2, 2, 4), false)
  assert.equal(Bounds.catalogRoom(4096, 0, Bounds.LIMITS.catalogApps), false)
})

test("chunkOverflow only trips above the cap", () => {
  assert.equal(Bounds.chunkOverflow(0, 4096), false)
  assert.equal(Bounds.chunkOverflow(4096, 4096), false)
  assert.equal(Bounds.chunkOverflow(4097, 4096), true)
  assert.equal(Bounds.chunkOverflow(0, 0), false)
  assert.equal(Bounds.chunkOverflow(1, 0), true)
})

// ---- stderr is bounded at the producer, synchronously before exit. ----
test("a small legitimate stderr is surfaced through the producer wrapper", () => {
  const dir = mkdtempSync(join(tmpdir(), "dropdown-stderr-"))
  try {
    const script = join(dir, "emit")
    writeFileSync(script, "#!/bin/sh\nprintf 'boom detail\\n' >&2\nexit 3\n")
    chmodSync(script, 0o755)
    const command = Bounds.producerCommand([script], 4096, 5)
    const result = spawnSync(command[0], command.slice(1), { timeout: 15000, encoding: null })
    assert.equal(result.status, 3)
    assert.equal(result.stderr.toString("utf8"), "boom detail\n")
  } finally {
    rmSync(dir, { recursive: true, force: true })
  }
})

test("a delayed stdout head does not lose stderr detail", () => {
  const dir = mkdtempSync(join(tmpdir(), "dropdown-delayed-head-"))
  try {
    const bin = join(dir, "bin")
    mkdirSync(bin, { recursive: true })
    // The wrapper resolves `head` from PATH; delay it by 50 ms and then exec
    // the real one. stderr must still be complete at exit.
    writeFileSync(join(bin, "head"), "#!/bin/sh\nsleep 0.05\nexec /usr/bin/head \"$@\"\n")
    chmodSync(join(bin, "head"), 0o755)
    const script = join(dir, "emit")
    writeFileSync(script, "#!/bin/sh\nprintf 'out\\n'\nprintf 'delayed detail\\n' >&2\nexit 7\n")
    chmodSync(script, 0o755)
    const command = Bounds.producerCommand([script], 4096, 5)
    for (let i = 0; i < 10; i++) {
      const result = spawnSync(command[0], command.slice(1), {
        timeout: 15000,
        encoding: null,
        env: { ...process.env, PATH: bin + ":" + process.env.PATH }
      })
      assert.equal(result.status, 7)
      assert.equal(result.stdout.toString("utf8"), "out\n")
      assert.equal(result.stderr.toString("utf8"), "delayed detail\n", "run " + i)
    }
  } finally {
    rmSync(dir, { recursive: true, force: true })
  }
})

test("exit codes survive the producer wrapper", () => {
  for (const code of [0, 1, 2, 3, 7, 124]) {
    const command = Bounds.producerCommand(["sh", "-c", "echo out; echo err >&2; exit " + code], 4096, 5)
    const result = spawnSync(command[0], command.slice(1), { timeout: 10000, encoding: null })
    assert.equal(result.status, code, "exit " + code)
    assert.equal(result.stdout.toString("utf8"), "out\n")
    assert.equal(result.stderr.toString("utf8"), "err\n")
  }
  const missing = Bounds.producerCommand(["dropdown-missing-tool-xyz"], 4096, 5)
  const result = spawnSync(missing[0], missing.slice(1), { timeout: 10000, encoding: null })
  assert.equal(result.status, 127)
})

test("stderr is capped at the producer and the helper still finishes", () => {
  // 50 MiB on stderr, then a marker on stdout and exit 0. The producer must
  // not die of SIGPIPE: the reader drains past its cap, so the run completes
  // and only cap+1 bytes are delivered.
  const command = Bounds.producerCommand(["sh", "-c",
    "head -c 52428800 /dev/zero | tr '\\0' e >&2; echo done; exit 0"], 4096, 10, 8192)
  const started = Date.now()
  const result = spawnSync(command[0], command.slice(1), { timeout: 30000, encoding: null })
  const elapsed = Date.now() - started
  assert.equal(result.status, 0)
  assert.equal(result.stdout.toString("utf8"), "done\n")
  assert.equal(result.stderr.length, 8193, "stderr must stop at cap+1 bytes")
  assert.ok(elapsed < 10000, "the drain must not block: " + elapsed + " ms")
})

test("stdout and stderr caps are independent", () => {
  const command = Bounds.producerCommand(["sh", "-c",
    "head -c 20000 /dev/zero | tr '\\0' o; head -c 20000 /dev/zero | tr '\\0' e >&2"], 4096, 10, 1024)
  const result = spawnSync(command[0], command.slice(1), { timeout: 20000, encoding: null })
  assert.equal(result.stdout.length, 4097)
  assert.equal(result.stderr.length, 1025)
})

test("a legitimate grandchild's stderr survives the wrapper", () => {
  const command = Bounds.producerCommand(["sh", "-c",
    "sh -c 'echo grandchild >&2' >&2; echo parent >&2; exit 0"], 4096, 5)
  const result = spawnSync(command[0], command.slice(1), { timeout: 10000, encoding: null })
  assert.equal(result.status, 0)
  assert.equal(result.stderr.toString("utf8"), "grandchild\nparent\n")
})

test("a timed-out wrapper leaves no orphan behind", () => {
  const marker = "dropdown-orphan-" + process.pid + "-" + Date.now()
  // exec -a keeps the marker visible in `ps`; the process replaces bash, so
  // it is the direct child of `timeout` and must not survive the deadline.
  const command = Bounds.producerCommand([
    "bash", "-c", "exec -a " + marker + " sleep 30"
  ], 1024, 1, 1024)
  const started = Date.now()
  const result = spawnSync(command[0], command.slice(1), { timeout: 15000, encoding: null })
  assert.equal(result.status, 124)
  assert.ok(Date.now() - started < 10000, "the deadline must fire near 1 s")
  const ps = spawnSync("ps", ["-eo", "args="], { encoding: "utf8" })
  const survivors = ps.stdout.split("\n").filter((line) => line.includes(marker))
  assert.deepEqual(survivors, [], "no child may outlive the wrapper")
})

test("complex argv (quotes, separators, UTF-8, newline) stays one argument", () => {
  const tricky = "a b;$(echo hi) q\"u'é\nline"
  const command = Bounds.producerCommand(["sh", "-c",
    "printf '[%s]' \"$1\"; printf 'E:%s' \"$2\" >&2", "x", tricky, tricky], 4096, 5)
  const result = spawnSync(command[0], command.slice(1), { timeout: 10000, encoding: null })
  assert.equal(result.status, 0)
  const expected = "[" + tricky + "]"
  assert.equal(result.stdout.toString("utf8"), expected)
  assert.equal(result.stderr.toString("utf8"), "E:" + tricky)
})

// ---- Per-chunk cap algorithm on a real 50 MiB stream. ----
// Mirrors BoundedProcess._watchStream: accumulate each chunk, ask the shared
// `Bounds.chunkOverflow`, and kill the producer on the chunk that crosses the
// cap. The component uses the same decision function on Qt's per-chunk
// `dataChanged` (waitForEnd: false). This proves the memory bound on real
// streams, not the Qt signal wiring (no Quickshell runtime is available here).
function runChunkCap(script, stream, cap) {
  return new Promise((resolve) => {
    const child = spawn("bash", ["-c", script], { stdio: ["ignore", "pipe", "pipe"] })
    const source = stream === "stderr" ? child.stderr : child.stdout
    let text = ""
    let rawBytes = 0
    let chunks = 0
    let lastChunkBytes = 0
    let killed = false
    function onChunk(buffer) {
      if (killed) return
      chunks++
      rawBytes += buffer.length
      lastChunkBytes = buffer.length
      // ASCII payload: UTF-16 length equals byte length.
      text += buffer.toString("utf8")
      if (Bounds.chunkOverflow(text.length, cap)) {
        killed = true
        child.kill("SIGKILL")
      }
    }
    source.on("data", onChunk)
    child.on("close", () => resolve({
      textLength: text.length, rawBytes, chunks, lastChunkBytes, killed
    }))
  })
}

test("50 MiB stdout stops at the per-chunk cap, not at 50 MiB", async () => {
  const cap = 4096
  const result = await runChunkCap("head -c 52428800 /dev/zero | tr '\\0' a", "stdout", cap)
  assert.equal(result.killed, true)
  assert.ok(result.rawBytes < 1024 * 1024, "must not accumulate 50 MiB: " + result.rawBytes)
  assert.ok(result.textLength <= cap + result.lastChunkBytes)
  assert.ok(result.textLength > cap)
})

test("50 MiB stderr stops at the per-chunk cap, not at 50 MiB", async () => {
  const cap = 1024
  const result = await runChunkCap("head -c 52428800 /dev/zero | tr '\\0' e >&2", "stderr", cap)
  assert.equal(result.killed, true)
  assert.ok(result.rawBytes < 1024 * 1024, "must not accumulate 50 MiB: " + result.rawBytes)
  assert.ok(result.textLength <= cap + result.lastChunkBytes)
  assert.ok(result.textLength > cap)
})

// ---- Config backup: the exact command the service runs, awaited. ----
function backupCommand(source, target) {
  return Bounds.producerCommand(["cp", "--", source, target], 1024, 4, 4096)
}

test("the bounded backup copies the old file before any deferred write", async () => {
  const dir = mkdtempSync(join(tmpdir(), "dropdown-backup-"))
  try {
    const bin = join(dir, "bin")
    mkdirSync(bin, { recursive: true })
    writeFileSync(join(bin, "cp"), "#!/bin/sh\nsleep 0.3\n/bin/cp \"$@\"\n")
    chmodSync(join(bin, "cp"), 0o755)
    const source = join(dir, "dropdown.json")
    const target = join(dir, "dropdown.json.bak-test")
    writeFileSync(source, "OLD")
    const command = backupCommand(source, target)
    const child = spawn(command[0], command.slice(1), {
      env: { ...process.env, PATH: bin + ":" + process.env.PATH },
      stdio: "ignore"
    })
    await new Promise((resolve) => setTimeout(resolve, 100))
    assert.equal(existsSync(target), false, "the write must wait for the backup")
    const status = await new Promise((resolve) => child.on("close", resolve))
    assert.equal(status, 0)
    assert.equal(readFileSync(target, "utf8"), "OLD")
    // The deferred write happens after the copy; the backup keeps the old text.
    writeFileSync(source, "NEW")
    assert.equal(readFileSync(target, "utf8"), "OLD")
  } finally {
    rmSync(dir, { recursive: true, force: true })
  }
})

test("a failing bounded backup leaves no copy and the source intact", () => {
  const dir = mkdtempSync(join(tmpdir(), "dropdown-backup-"))
  try {
    const bin = join(dir, "bin")
    mkdirSync(bin, { recursive: true })
    writeFileSync(join(bin, "cp"), "#!/bin/sh\nexit 1\n")
    chmodSync(join(bin, "cp"), 0o755)
    const source = join(dir, "dropdown.json")
    const target = join(dir, "dropdown.json.bak-test")
    writeFileSync(source, "OLD")
    const command = backupCommand(source, target)
    const result = spawnSync(command[0], command.slice(1), {
      env: { ...process.env, PATH: bin + ":" + process.env.PATH },
      timeout: 15000,
      encoding: null
    })
    assert.notEqual(result.status, 0)
    assert.equal(existsSync(target), false)
    assert.equal(readFileSync(source, "utf8"), "OLD")
  } finally {
    rmSync(dir, { recursive: true, force: true })
  }
})

test("a blocked bounded backup times out without writing the target", () => {
  const dir = mkdtempSync(join(tmpdir(), "dropdown-backup-"))
  try {
    const bin = join(dir, "bin")
    mkdirSync(bin, { recursive: true })
    writeFileSync(join(bin, "cp"), "#!/bin/sh\nsleep 30\n")
    chmodSync(join(bin, "cp"), 0o755)
    const source = join(dir, "dropdown.json")
    const target = join(dir, "dropdown.json.bak-test")
    writeFileSync(source, "OLD")
    const command = backupCommand(source, target)
    const started = Date.now()
    const result = spawnSync(command[0], command.slice(1), {
      env: { ...process.env, PATH: bin + ":" + process.env.PATH },
      timeout: 20000,
      encoding: null
    })
    assert.equal(result.status, 124)
    assert.equal(existsSync(target), false)
    assert.equal(readFileSync(source, "utf8"), "OLD")
    assert.ok(Date.now() - started < 10000, "the producer deadline must fire")
  } finally {
    rmSync(dir, { recursive: true, force: true })
  }
})

test("the bounded prune keeps the five most recent backups", () => {
  const dir = mkdtempSync(join(tmpdir(), "dropdown-prune-"))
  try {
    const source = join(dir, "dropdown.json")
    writeFileSync(source, "{}")
    const names = []
    for (let i = 0; i < 8; i++) {
      const name = source + ".bak-2026010" + i + "-00000" + i
      writeFileSync(name, "backup " + i)
      const stamp = new Date(2026, 0, 1, 0, 0, i)
      utimesSync(name, stamp, stamp)
      names.push(name)
    }
    const command = Bounds.producerCommand(ConfigFile.pruneCommand(source), 1024, 4, 2048)
    const result = spawnSync(command[0], command.slice(1), { timeout: 10000, encoding: null })
    assert.equal(result.status, 0)
    const left = names.filter((name) => existsSync(name))
    assert.equal(left.length, 5)
    // The three oldest (lowest mtime) are removed; the source is untouched.
    assert.equal(existsSync(source), true)
    assert.deepEqual(left, names.slice(3))
  } finally {
    rmSync(dir, { recursive: true, force: true })
  }
})

test("after a failed adoption backup, an automatic save writes nothing", () => {
  // Compose the real failed copy with the service gate (the shared
  // configSaveAction policy): the barrier is restored and an automatic save
  // is blocked, leaving the external file untouched. Only an explicit save
  // asks for a backup again.
  const dir = mkdtempSync(join(tmpdir(), "dropdown-adopt-"))
  try {
    const bin = join(dir, "bin")
    mkdirSync(bin, { recursive: true })
    writeFileSync(join(bin, "cp"), "#!/bin/sh\nexit 1\n")
    chmodSync(join(bin, "cp"), 0o755)
    const source = join(dir, "dropdown.json")
    const target = join(dir, "dropdown.json.bak-test")
    writeFileSync(source, "EXTERNAL")
    const command = backupCommand(source, target)
    const copy = spawnSync(command[0], command.slice(1), {
      env: { ...process.env, PATH: bin + ":" + process.env.PATH },
      timeout: 15000,
      encoding: null
    })
    assert.notEqual(copy.status, 0)
    let refused = true // blockConfigWritesAfterBackupFailure on copy failure
    let writes = 0
    if (Bounds.configSaveAction(refused, false) !== "blocked") writes++
    assert.equal(writes, 0)
    assert.equal(readFileSync(source, "utf8"), "EXTERNAL")
    assert.equal(Bounds.configSaveAction(refused, true), "backup")
    // The explicit retry uses the real cp and succeeds, then the write runs.
    const retry = backupCommand(source, target)
    const ok = spawnSync(retry[0], retry.slice(1), { timeout: 15000, encoding: null })
    assert.equal(ok.status, 0)
    assert.equal(readFileSync(target, "utf8"), "EXTERNAL")
    if (Bounds.configSaveAction(refused, true) === "backup" && ok.status === 0) writes++
    assert.equal(writes, 1)
  } finally {
    rmSync(dir, { recursive: true, force: true })
  }
})

test("enqueueBatch refuses the newest item when full instead of dropping one", () => {
  let queue = []
  for (let i = 0; i < 8; i++) {
    const result = Bounds.enqueueBatch(queue, { id: i }, Bounds.LIMITS.batchQueueItems)
    assert.equal(result.accepted, true)
    queue = result.queue
  }
  const rejected = Bounds.enqueueBatch(queue, { id: 8 }, Bounds.LIMITS.batchQueueItems)
  assert.equal(rejected.accepted, false)
  assert.deepEqual(rejected.queue.map((entry) => entry.id), [0, 1, 2, 3, 4, 5, 6, 7])
})

// ---- Busy batch path: queued, ordered, callback exactly once, no detach. ----
// Drives the same admission rule and producer wrapper the service uses. A
// fake slow `hyprctl` logs each batch; five arrive while the first runs.
test("queued batches run in order, slowly, and each callback fires once", async () => {
  const dir = mkdtempSync(join(tmpdir(), "dropdown-batch-"))
  try {
    const bin = join(dir, "bin")
    mkdirSync(bin, { recursive: true })
    const log = join(dir, "log")
    writeFileSync(join(bin, "hyprctl"), "#!/bin/sh\nsleep 0.1\nprintf '%s\\n' \"$2\" >> " + log + "\n")
    chmodSync(join(bin, "hyprctl"), 0o755)
    const calls = []
    let queue = []
    let running = false
    let current = null
    function run(item) {
      running = true
      current = item
      const command = Bounds.producerCommand(item.command, 4096, 3, 8192)
      const child = spawn(command[0], command.slice(1), {
        env: { ...process.env, PATH: bin + ":" + process.env.PATH },
        stdio: "ignore"
      })
      child.on("close", (status) => {
        running = false
        calls.push(item.id + ":" + status)
        const next = queue.shift()
        if (next) run(next)
      })
    }
    function submit(id) {
      const item = { id, command: ["hyprctl", "--batch", "dispatch id=" + id], callback: () => {} }
      if (running) {
        const result = Bounds.enqueueBatch(queue, item, Bounds.LIMITS.batchQueueItems)
        queue = result.queue
        assert.equal(result.accepted, true)
        return
      }
      run(item)
    }
    submit(0)
    await new Promise((resolve) => setTimeout(resolve, 20))
    for (let i = 1; i <= 4; i++) submit(i)
    assert.equal(queue.length, 4, "batches arriving during the first run are queued")
    await new Promise((resolve) => setTimeout(resolve, 1500))
    assert.deepEqual(calls, ["0:0", "1:0", "2:0", "3:0", "4:0"])
    const lines = readFileSync(log, "utf8").trim().split("\n")
    assert.deepEqual(lines, ["dispatch id=0", "dispatch id=1", "dispatch id=2",
      "dispatch id=3", "dispatch id=4"])
  } finally {
    rmSync(dir, { recursive: true, force: true })
  }
})

test("a saturated batch queue still settles every callback", () => {
  // Policy mirror: a rejected batch logs and calls back immediately; accepted
  // batches call back once when their process settles.
  const events = []
  let queue = []
  function submit(id, running) {
    const item = { id, callback: () => events.push(id) }
    if (running) {
      const result = Bounds.enqueueBatch(queue, item, 2)
      queue = result.queue
      if (!result.accepted) item.callback()
      return
    }
    item.callback()
  }
  submit(1, true)
  submit(2, true)
  submit(3, true) // saturated: callback now
  assert.deepEqual(queue.map((entry) => entry.id), [1, 2])
  assert.deepEqual(events, [3])
  for (const item of queue) item.callback()
  assert.deepEqual(events, [3, 1, 2])
})
